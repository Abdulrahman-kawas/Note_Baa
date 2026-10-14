import BackgroundTasks
import Foundation
import Observation

/// Long jobs the student starts after a lecture (fill gaps, refine translation, full re-transcription).
/// They live here, not in a view, so leaving the screen doesn't cancel them; a
/// `BGContinuedProcessingTask` (iPadOS 26) keeps them running in the background with a system
/// progress Live Activity. If the system refuses the request, the work still runs in the foreground.
@MainActor
@Observable
final class BackgroundWork {
    static let shared = BackgroundWork()
    /// Must be listed in Info.plist ▸ BGTaskSchedulerPermittedIdentifiers.
    static var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "com.dawwen") + ".postlecture" }

    private(set) var status: [UUID: String] = [:]
    private(set) var running: Set<UUID> = []

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var systemTask: BGContinuedProcessingTask?
    @ObservationIgnored private var fraction = 0.0
    @ObservationIgnored private var message = ""
    @ObservationIgnored private var registered = false

    /// Call once at launch.
    func registerLaunchHandler() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated { BackgroundWork.shared.adopt(task) }
        }
    }

    typealias ProgressHandler = @MainActor @Sendable (_ fraction: Double, _ message: String) -> Void

    /// Starts `work` for one lecture unless a job for it is already running. Must be called from a
    /// tap: the system only accepts continued-processing requests that a person started.
    func start(lectureID: UUID, title: String, work: @escaping @MainActor (_ progress: @escaping ProgressHandler) async throws -> String) {
        guard tasks[lectureID] == nil else { return }
        running.insert(lectureID)
        status[lectureID] = "Starting…"
        tasks[lectureID] = Task { [weak self] in
            guard let self else { return }
            let result: String
            do {
                result = try await work { fraction, message in self.report(lectureID, fraction, message) }
            } catch is CancellationError {
                result = "Cancelled."
            } catch {
                result = "Couldn't finish: \(error.localizedDescription)"
            }
            self.finish(lectureID, message: result, success: !Task.isCancelled)
        }
        submitSystemTask(title: title)
    }

    func cancel(lectureID: UUID) {
        tasks[lectureID]?.cancel()
    }

    func clearStatus(lectureID: UUID) {
        if tasks[lectureID] == nil { status[lectureID] = nil }
    }

    // MARK: - System task

    private func submitSystemTask(title: String) {
        guard registered, systemTask == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier, title: title, subtitle: "Continues even if you leave the app"
        )
        request.strategy = .fail // run now or not at all; the work continues in the foreground anyway
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Foreground only. Nothing else to do.
        }
    }

    private func adopt(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, !tasks.isEmpty else {
            task.setTaskCompleted(success: true)
            return
        }
        systemTask = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = {
            // The person cancelled from the system UI, or the system needs the resources back.
            Task { @MainActor in BackgroundWork.shared.cancelAll() }
        }
        updateSystemProgress()
    }

    private func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    private func report(_ lectureID: UUID, _ fraction: Double, _ message: String) {
        status[lectureID] = message
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
        updateSystemProgress()
    }

    private func updateSystemProgress() {
        guard let task = systemTask else { return }
        task.progress.completedUnitCount = Int64((fraction * 100).rounded())
        task.updateTitle(task.title, subtitle: message)
    }

    private func finish(_ lectureID: UUID, message: String, success: Bool) {
        tasks[lectureID] = nil
        running.remove(lectureID)
        status[lectureID] = message
        guard tasks.isEmpty, let task = systemTask else { return }
        task.progress.completedUnitCount = 100
        task.setTaskCompleted(success: success)
        systemTask = nil
    }
}
