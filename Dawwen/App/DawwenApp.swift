import SwiftUI
import SwiftData

@main
struct DawwenApp: App {
    let container: ModelContainer

    init() {
        AppSettings.registerDefaults()
        do {
            container = try ModelContainer(for: Lecture.self, TranscriptSegment.self)
        } catch {
            fatalError("Could not open the lecture database: \(error)")
        }
        // A lecture still marked "recording" means the app died mid-lecture.
        LectureStore.recoverInterruptedLectures(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .modelContainer(container)
    }
}
