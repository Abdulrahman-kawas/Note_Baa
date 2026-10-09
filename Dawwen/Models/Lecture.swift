import Foundation
import SwiftData

enum LectureStatus: String, Codable {
    case recording
    case interrupted
    case ready
}

@Model
final class Lecture {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    /// Seconds of recorded audio.
    var duration: Double
    /// BCP-47 identifier of the spoken language, e.g. "ar-SA".
    var sourceLanguage: String
    /// Translation target, nil when translation is off.
    var targetLanguage: String?
    var engineRaw: String
    var statusRaw: String
    /// Audio part files inside the lecture folder, in recording order.
    var audioSegments: [String]
    /// Seconds into the recording that the student marked as important.
    var bookmarks: [Double]
    /// True when part of the audio has no transcript yet (heat, network, crash, import).
    var transcriptionIncomplete: Bool
    var summary: String?
    var summaryModel: String?
    var summaryDate: Date?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.lecture)
    var segments: [TranscriptSegment] = []

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
}
