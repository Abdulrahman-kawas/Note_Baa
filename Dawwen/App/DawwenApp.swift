import SwiftData
import SwiftUI

@main
struct DawwenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private enum Startup {
        case ready(ModelContainer)
        case failed(String)
    }

    private let startup: Startup

    init() {
        AppSettings.registerDefaults()
        LectureStore.migrateLegacyFolderIfNeeded()
        LectureExporter.cleanTemporaryExports()
        do {
            let container = try Self.makeContainer()
            // A lecture still marked "recording" means the app died mid-lecture.
            LectureStore.recoverInterruptedLectures(in: container.mainContext)
            BackupUploader.shared.container = container
            BackgroundWork.shared.registerLaunchHandler()
            startup = .ready(container)
        } catch {
            // Never crash on a database problem: the audio is safe, offer recovery instead.
            startup = .failed(String(describing: error))
        }
    }

    /// Versioned schema + migration plan. The store stays at the default location used by 0.1.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: DawwenMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema)
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch startup {
                case .ready(let container):
                    LibraryView()
                        .modelContainer(container)
                case .failed(let message):
                    DatabaseRecoveryView(message: message)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await BackupUploader.shared.enqueuePending() }
                }
            }
        }
    }
}
