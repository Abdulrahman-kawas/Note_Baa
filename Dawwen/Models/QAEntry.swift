import Foundation
import SwiftData

typealias QAEntry = SchemaV2.QAEntry

extension SchemaV2 {
    /// A question asked about a lecture and the answer that came back. Kept so the study notes survive
    /// the session. Added in V2 with no changes to existing entities, so the migration is lightweight.
    @Model
    final class QAEntry {
        var id: UUID
        var question: String
        var answer: String
        var createdAt: Date
        var lecture: Lecture?

        init(question: String, answer: String) {
            self.id = UUID()
            self.question = question
            self.answer = answer
            self.createdAt = .now
        }
    }
}
