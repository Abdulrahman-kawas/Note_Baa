import Foundation
import Observation
import Translation

/// Feeds finalized phrases to Apple's on-device translator, one at a time, in order.
///
/// A view attaches `.translationTask(configuration) { await queue.run(with: $0) }`; the system
/// asks to download the language pair the first time, then works offline.
@MainActor
@Observable
final class TranslationQueue {
    private(set) var pendingCount = 0
    private(set) var lastError: String?

    @ObservationIgnored var onTranslated: ((UUID, String) -> Void)?
    @ObservationIgnored private var jobs: [(id: UUID, text: String)] = []

    func enqueue(id: UUID, text: String) {
        jobs.append((id, text))
        pendingCount = jobs.count
    }

    func removeAll() {
        jobs.removeAll()
        pendingCount = 0
    }

    func run(with session: TranslationSession) async {
        while !Task.isCancelled {
            guard !jobs.isEmpty else {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            let job = jobs.removeFirst()
            pendingCount = jobs.count
            do {
                let response = try await session.translate(job.text)
                onTranslated?(job.id, response.targetText)
                lastError = nil
            } catch is CancellationError {
                jobs.insert(job, at: 0) // Retried by the next session.
                pendingCount = jobs.count
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
