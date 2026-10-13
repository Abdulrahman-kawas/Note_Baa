import Foundation
import SwiftData

/// Everything about a lecture except its audio, as `lecture.json` in the lecture folder. Written
/// after recording, gap filling, summaries and refinement; backed up with the audio. If the
/// database is ever lost, `restoreAll` rebuilds the library from these files.
struct LectureArchive: Codable {
    struct Segment: Codable {
        var uid: UUID
        var start: Double
        var end: Double
        var text: String
        var translation: String?
        var refinedTranslation: String?
        var speaker: String?
    }

    var formatVersion = 1
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var sourceLanguage: String
    var targetLanguage: String?
    var engine: String
    var audioSegments: [String]
    var bookmarks: [Double]
    var gaps: [TranscriptGap]
    var summary: String?
    var summaryOriginal: String?
    var summaryModel: String?
    var summaryDate: Date?
    var segments: [Segment]

    static let fileName = "lecture.json"

    @MainActor
    init(_ lecture: Lecture) {
        id = lecture.id
        title = lecture.title
        createdAt = lecture.createdAt
        duration = lecture.duration
        sourceLanguage = lecture.sourceLanguage
        targetLanguage = lecture.targetLanguage
        engine = lecture.engineRaw
        audioSegments = lecture.audioSegments
        bookmarks = lecture.bookmarks
        gaps = lecture.gaps
        summary = lecture.summary
        summaryOriginal = lecture.summaryOriginal
        summaryModel = lecture.summaryModel
        summaryDate = lecture.summaryDate
        segments = lecture.sortedSegments.map {
            Segment(uid: $0.uid, start: $0.start, end: $0.end, text: $0.text,
                    translation: $0.translation, refinedTranslation: $0.refinedTranslation, speaker: $0.speaker)
        }
    }

    static func url(for id: UUID) -> URL {
        LectureStore.folder(for: id).appending(path: fileName)
    }

    @MainActor
    @discardableResult
    static func write(_ lecture: Lecture) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = url(for: lecture.id)
        try encoder.encode(LectureArchive(lecture)).write(to: url, options: .atomic)
        return url
    }

    /// Re-creates lectures that are on disk but missing from the database. Returns how many.
    @MainActor
    static func restoreAll(into context: ModelContext) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existing = Set(try context.fetch(FetchDescriptor<Lecture>()).map(\.id))
        let folders = (try? FileManager.default.contentsOfDirectory(at: LectureStore.rootFolder, includingPropertiesForKeys: nil)) ?? []
        var restored = 0
        for folder in folders {
            let file = folder.appending(path: fileName)
            guard let data = try? Data(contentsOf: file),
                  let archive = try? decoder.decode(LectureArchive.self, from: data),
                  !existing.contains(archive.id) else { continue }
            let lecture = Lecture(title: archive.title, sourceLanguage: archive.sourceLanguage,
                                  targetLanguage: archive.targetLanguage, engine: EngineKind(rawValue: archive.engine) ?? .none)
            lecture.id = archive.id
            lecture.createdAt = archive.createdAt
            lecture.duration = archive.duration
            lecture.audioSegments = LectureStore.partFileNames(in: folder)
            lecture.bookmarks = archive.bookmarks
            lecture.gaps = archive.gaps
            lecture.transcriptionIncomplete = !archive.gaps.isEmpty
            lecture.summary = archive.summary
            lecture.summaryOriginal = archive.summaryOriginal
            lecture.summaryModel = archive.summaryModel
            lecture.summaryDate = archive.summaryDate
            lecture.status = .ready
            context.insert(lecture)
            for item in archive.segments {
                let segment = TranscriptSegment(start: item.start, end: item.end, text: item.text, speaker: item.speaker)
                segment.uid = item.uid
                segment.translation = item.translation
                segment.refinedTranslation = item.refinedTranslation
                context.insert(segment)
                segment.lecture = lecture
            }
            restored += 1
        }
        try context.save()
        return restored
    }
}
