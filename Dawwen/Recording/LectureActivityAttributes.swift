import ActivityKit
import Foundation

/// Shared by the app and the widget extension. Add this file to both targets (File Inspector ← Target Membership).
struct LectureActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
    }

    var title: String
    /// When the recording started; the widget counts up from here with a system timer.
    var startedAt: Date
}
