import AVFoundation
import Foundation
import SwiftData

/// Where lecture audio lives on disk, and recovery after a crash.
///
/// Since 0.2 the audio lives in Application Support (hidden from the Files app, still in the
/// device backup); 0.1 kept it in Documents/Lectures, which is moved once at launch.
enum LectureStore {
    static var rootFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Lectures", directoryHint: .isDirectory)
    }

    static var legacyRootFolder: URL {
        URL.documentsDirectory.appending(path: "Lectures", directoryHint: .isDirectory)
    }

    /// Files that could not be read are moved here, never deleted.
    static var recoveryFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Recovery", directoryHint: .isDirectory)
    }

    static func folder(for id: UUID) -> URL {
        rootFolder.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    @discardableResult
    static func createFolder(for id: UUID) throws -> URL {
        let url = folder(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func audioURLs(for lecture: Lecture) -> [URL] {
        let folder = folder(for: lecture.id)
        return lecture.audioSegments.map { folder.appending(path: $0) }
    }

    /// Part files in recording order. A finished m4a wins over the CAF of the same index.
    static func partFileNames(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var byIndex: [Int: String] = [:]
        for name in names where AudioPartFile.isPart(name) {
            guard let index = AudioPartFile.index(of: name) else { continue }
            if let existing = byIndex[index], existing.hasSuffix(".\(AudioPartFile.archiveExtension)") { continue }
            byIndex[index] = name
        }
        return byIndex.keys.sorted().compactMap { byIndex[$0] }
    }

    /// Total length of the readable files; unreadable ones count as zero.
    static func duration(of urls: [URL]) -> Double {
        urls.reduce(0) { total, url in
            guard let file = try? AVAudioFile(forReading: url) else { return total }
            return total + Double(file.length) / file.processingFormat.sampleRate
        }
    }

    static func deleteFiles(for lecture: Lecture) {
        try? FileManager.default.removeItem(at: folder(for: lecture.id))
    }

    static func migrateLegacyFolderIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyRootFolder.path) else { return }
        try? fileManager.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: rootFolder.path) {
            try? fileManager.moveItem(at: legacyRootFolder, to: rootFolder)
            return
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: legacyRootFolder.path)) ?? [] {
            let target = rootFolder.appending(path: name)
            if !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: legacyRootFolder.appending(path: name), to: target)
            }
        }
    }

    private static func moveToRecovery(_ url: URL, lectureID: UUID) {
        let folder = recoveryFolder.appending(path: lectureID.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: "\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)")
        try? FileManager.default.moveItem(at: url, to: target)
    }

    /// A lecture still marked `.recording` at launch means the app died mid-lecture. The open PCM
    /// part is repaired and archived; closed parts are intact; nothing unreadable is deleted.
    @MainActor
    static func recoverInterruptedLectures(in context: ModelContext) {
        let recording = LectureStatus.recording.rawValue
        let descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw == recording })
        guard let lectures = try? context.fetch(descriptor) else { return }
        let fileManager = FileManager.default
        for lecture in lectures {
            let folder = folder(for: lecture.id)
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                let url = folder.appending(path: name)
                if name.contains(".tmp.") {
                    try? fileManager.removeItem(at: url) // half-written transcode; its CAF is still there
                } else if name.hasSuffix(".\(AudioPartFile.openExtension)") {
                    _ = try? AudioPartFile.repairCAF(at: url)
                    if (try? AudioPartFile.transcodeToAAC(url)) == nil, fileManager.fileExists(atPath: url.path),
                       (try? AVAudioFile(forReading: url)) == nil {
                        moveToRecovery(url, lectureID: lecture.id)
                    }
                } else if name.hasSuffix(".\(AudioPartFile.archiveExtension)"), (try? AVAudioFile(forReading: url)) == nil {
                    moveToRecovery(url, lectureID: lecture.id)
                }
            }
            let kept = partFileNames(in: folder)
            lecture.audioSegments = kept
            lecture.duration = duration(of: kept.map { folder.appending(path: $0) })
            if lecture.engine == .none {
                lecture.addGap(TranscriptGap(start: 0, end: lecture.duration, reason: .recordOnly))
            } else {
                // Text stops where the app died, and long silences may hide unreported gaps.
                let spans = lecture.segments.map { (start: $0.start, end: $0.end) }
                for gap in GapMath.inferred(from: spans, duration: lecture.duration, minimum: 30) {
                    lecture.addGap(TranscriptGap(start: gap.start, end: gap.end, reason: .crash))
                }
            }
            lecture.status = .interrupted
            lecture.transcriptionIncomplete = !lecture.gaps.isEmpty
            try? LectureArchive.write(lecture)
        }
        try? context.save()
    }
}
