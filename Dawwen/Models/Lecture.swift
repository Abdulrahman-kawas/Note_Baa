import Foundation
import SwiftData

/// The app always works with the latest schema version.
typealias Lecture = SchemaV2.Lecture
typealias TranscriptSegment = SchemaV2.TranscriptSegment

enum LectureStatus: String, Codable {
    case recording
    case interrupted
    case ready
}

/// Version 2: adds gap tracking, backup state, gateway jobs and refined translations.
/// Every new property is optional, so the move from V1 is a lightweight migration.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Lecture.self, TranscriptSegment.self, QAEntry.self] }

    @Model
    final class Lecture {
        @Attribute(.unique) var id: UUID
        var title: String
        var createdAt: Date
        /// Seconds of recorded audio.
        var duration: Double
        /// BCP-47 identifier of the spoken language, e.g. "en-US".
        var sourceLanguage: String
        /// Translation target, nil when translation is off.
        var targetLanguage: String?
        var engineRaw: String
        var statusRaw: String
        /// Audio part files inside the lecture folder, in recording order.
        var audioSegments: [String]
        /// Seconds into the recording that the student marked as important.
        var bookmarks: [Double]
        /// True while `gaps` is not empty (kept for V1 data, which has no gap list).
        var transcriptionIncomplete: Bool
        var summary: String?
        var summaryModel: String?
        var summaryDate: Date?
        @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.lecture)
        var segments: [TranscriptSegment] = []

        // MARK: V2
        /// JSON `[TranscriptGap]`: stretches of audio that have no transcript yet.
        var gapsData: Data?
        /// JSON `[String]`: part files already copied to the off-device backup.
        var uploadedPartsData: Data?
        var archiveUploadedAt: Date?
        /// The summary in the lecture's own language when `summary` holds its translation.
        var summaryOriginal: String?
        /// Gateway jobs that deliver later (Message Batches or the home worker).
        var summaryJobID: String?
        var refineJobID: String?
        var translationRefinedAt: Date?
        /// Questions asked about this lecture, newest last.
        @Relationship(deleteRule: .cascade, inverse: \QAEntry.lecture)
        var questions: [QAEntry] = []

        init(title: String, sourceLanguage: String, targetLanguage: String?, engine: EngineKind) {
            self.id = UUID()
            self.title = title
            self.createdAt = .now
            self.duration = 0
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.engineRaw = engine.rawValue
            self.statusRaw = LectureStatus.recording.rawValue
            self.audioSegments = []
            self.bookmarks = []
            self.transcriptionIncomplete = false
        }
    }
}

enum DawwenMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}

extension SchemaV2.Lecture {
    var status: LectureStatus {
        get { LectureStatus(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    var engine: EngineKind {
        EngineKind(rawValue: engineRaw) ?? .none
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }

    /// Stretches without transcript, merged and sorted.
    var gaps: [TranscriptGap] {
        get {
            guard let gapsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptGap].self, from: gapsData)) ?? []
        }
        set {
            let merged = GapMath.merged(newValue)
            gapsData = merged.isEmpty ? nil : try? JSONEncoder().encode(merged)
        }
    }

    var untranscribedSeconds: Double { gaps.reduce(0) { $0 + $1.duration } }

    func addGap(_ gap: TranscriptGap) {
        guard gap.duration >= 0.3 else { return }
        gaps = gaps + [gap]
        transcriptionIncomplete = true
    }

    /// Removes every stored gap that lies inside `range` (the caller has transcribed it).
    func clearGaps(within start: Double, _ end: Double) {
        gaps = gaps.filter { !($0.start >= start - 0.01 && $0.end <= end + 0.01) }
        transcriptionIncomplete = !gaps.isEmpty
    }

    var uploadedParts: Set<String> {
        get {
            guard let uploadedPartsData else { return [] }
            return Set((try? JSONDecoder().decode([String].self, from: uploadedPartsData)) ?? [])
        }
        set { uploadedPartsData = try? JSONEncoder().encode(newValue.sorted()) }
    }
}
