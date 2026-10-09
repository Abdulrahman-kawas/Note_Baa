import Foundation
import SwiftData

/// One finalized phrase of the transcript, with its position in the recording.
@Model
final class TranscriptSegment {
    var uid: UUID
    var start: Double
    var end: Double
    var text: String
    var translation: String?
    var speaker: String?
    var lecture: Lecture?

    init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.uid = UUID()
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}
