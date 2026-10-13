import ActivityKit
import Foundation

/// Shows the recording on the Lock Screen and in the Dynamic Island. Best effort: if the system refuses
/// (Live Activities turned off), the recording goes on without it.
@MainActor
final class LectureActivityController {
    private var activity: Activity<LectureActivityAttributes>?

    func start(title: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Activities left over from an earlier run would otherwise stay on the Lock Screen.
        for stale in Activity<LectureActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = LectureActivityAttributes(title: title, startedAt: startedAt)
        let content = ActivityContent(state: LectureActivityAttributes.ContentState(isPaused: false), staleDate: nil)
        activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func setPaused(_ paused: Bool) {
        guard let activity else { return }
        let content = ActivityContent(state: LectureActivityAttributes.ContentState(isPaused: paused), staleDate: nil)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
