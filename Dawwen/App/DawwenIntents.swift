import AppIntents
import Observation

/// Lets Shortcuts, Spotlight, Siri and the Action button open the new-lecture sheet.
struct StartLectureIntent: AppIntent {
    static var title: LocalizedStringResource = "ابدأ محاضرة جديدة"
    static var description = IntentDescription("يفتح دوّن لبدء تسجيل محاضرة جديدة.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LectureRouter.shared.requestNewLecture()
        return .result()
    }
}

struct DawwenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartLectureIntent(),
            phrases: ["ابدأ محاضرة في \(.applicationName)", "Start a lecture in \(.applicationName)"],
            shortTitle: "محاضرة جديدة",
            systemImageName: "record.circle"
        )
    }
}

/// Carries a request from outside the UI (an intent) to the library screen, which owns the sheet.
@MainActor
@Observable
final class LectureRouter {
    static let shared = LectureRouter()

    var newLectureRequested = false

    func requestNewLecture() {
        newLectureRequested = true
    }

    /// Returns true once per request, so the sheet opens exactly once.
    func consumeNewLectureRequest() -> Bool {
        guard newLectureRequested else { return false }
        newLectureRequested = false
        return true
    }
}
