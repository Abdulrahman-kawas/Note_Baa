import Foundation
import SwiftData
import AVFoundation

/// Where lecture audio lives on disk, and recovery after a crash.
enum LectureStore {
    static var rootFolder: URL {
        URL.documentsDirectory.appending(path: "Lectures", directoryHint: .isDirectory)
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

    /// Recorded part files in the folder, in order ("part-000.m4a", "part-001.m4a", …).
    static func partFileNames(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("part-") && $0.hasSuffix(".m4a") }.sorted()
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

    /// A lecture still marked `.recording` at launch means the app died mid-lecture.
    /// Every closed 5-minute part is intact; only the part that was open is lost.
    @MainActor
    static func recoverInterruptedLectures(in context: ModelContext) {
        let recording = LectureStatus.recording.rawValue
        let descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw == recording })
        guard let lectures = try? context.fetch(descriptor) else { return }
        for lecture in lectures {
            let folder = folder(for: lecture.id)
            var kept: [String] = []
            for name in partFileNames(in: folder) {
                let url = folder.appending(path: name)
                if (try? AVAudioFile(forReading: url)) != nil {
                    kept.append(name)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            lecture.audioSegments = kept
            lecture.duration = duration(of: kept.map { folder.appending(path: $0) })
            lecture.status = .interrupted
            lecture.transcriptionIncomplete = true
        }
        try? context.save()
    }
}
