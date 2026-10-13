import Foundation
import SwiftData

extension SchemaV2 {
    /// One finalized phrase of the transcript, with its position in the recording.
    @Model
    final class TranscriptSegment {
        var uid: UUID
        var start: Double
        var end: Double
        var text: String
        /// Apple Translation, sentence by sentence, during or right after the lecture.
        var translation: String?
        var speaker: String?
        var lecture: Lecture?
        // MARK: V2
        /// Context-aware translation made after the lecture (Claude or a local model). Kept beside
        /// `translation`, never over it.
        var refinedTranslation: String?

        init(start: Double, end: Double, text: String, speaker: String? = nil) {
            self.uid = UUID()
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }
    }
}

extension SchemaV2.TranscriptSegment {
    /// What the UI and exports show: the refined translation when there is one.
    var bestTranslation: String? { refinedTranslation ?? translation }
}
