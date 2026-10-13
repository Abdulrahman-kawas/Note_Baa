import Foundation
import SwiftData

/// The schema exactly as version 0.1 shipped it. Frozen: SwiftData recognises the existing store by
/// comparing it with these definitions, so never edit a property here. Changes go in a new version.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Lecture.self, TranscriptSegment.self] }

    @Model
    final class Lecture {
        @Attribute(.unique) var id: UUID
        var title: String
        var createdAt: Date
        var duration: Double
        var sourceLanguage: String
        var targetLanguage: String?
        var engineRaw: String
        var statusRaw: String
        var audioSegments: [String]
        var bookmarks: [Double]
        var transcriptionIncomplete: Bool
        var summary: String?
        var summaryModel: String?
        var summaryDate: Date?
        @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.lecture)
        var segments: [TranscriptSegment] = []

        init() {
            id = UUID()
            title = ""
            createdAt = .now
            duration = 0
            sourceLanguage = "en-US"
            engineRaw = "apple"
            statusRaw = "ready"
            audioSegments = []
            bookmarks = []
            transcriptionIncomplete = false
        }
    }

    @Model
    final class TranscriptSegment {
        var uid: UUID
        var start: Double
        var end: Double
        var text: String
        var translation: String?
        var speaker: String?
        var lecture: Lecture?

        init() {
            uid = UUID()
            start = 0
            end = 0
            text = ""
        }
    }
}
