import Foundation
import Observation
import Translation

/// Feeds finalized phrases to Apple's on-device translator, in order, in small batches.
///
/// Works with a session from `.translationTask` (can ask to download languages) or one created
/// directly from installed languages (`TranslationSupport.installedSession`, no view needed).
/// The queue itself is in memory; the durable queue is "segments whose `translation` is nil",
/// which the detail view translates automatically when the lecture is opened.
@MainActor
@Observable
final class TranslationQueue {
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var lastError: String?

    @ObservationIgnored var onTranslated: ((UUID, String) -> Void)?
    @ObservationIgnored private var jobs: [(id: UUID, text: String)] = []
    @ObservationIgnored private var wakeUp: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var closeWhenDrained = false

    /// Phrases arrive one by one during a lecture; after it, a batch keeps the model busy.
    private static let batchSize = 16

    func enqueue(id: UUID, text: String) {
        jobs.append((id, text))
        pendingCount = jobs.count
        wakeUp?.yield()
    }

    func removeAll() {
        jobs.removeAll()
        pendingCount = 0
    }

    /// `run(with:)` returns once the queue is empty instead of waiting for more.
    func finishWhenDrained() {
        closeWhenDrained = true
        wakeUp?.yield()
    }

    func run(with session: TranslationSession) async {
        let (signal, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeUp = continuation
        continuation.yield()
        defer {
            wakeUp = nil
            closeWhenDrained = false
        }
        for await _ in signal {
            while !jobs.isEmpty {
                if Task.isCancelled { return }
                let batch = Array(jobs.prefix(Self.batchSize))
                jobs.removeFirst(batch.count)
                do {
                    try await translate(batch, with: session)
                    lastError = nil
                } catch is CancellationError {
                    jobs.insert(contentsOf: batch, at: 0)
                    pendingCount = jobs.count
                    return
                } catch {
                    await translateOneByOne(batch, with: session)
                }
                pendingCount = jobs.count
            }
            if closeWhenDrained || Task.isCancelled { return }
        }
    }

    private func translate(_ batch: [(id: UUID, text: String)], with session: TranslationSession) async throws {
        let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        let responses = try await session.translations(from: requests)
        for response in responses {
            guard let raw = response.clientIdentifier, let id = UUID(uuidString: raw) else { continue }
            onTranslated?(id, response.targetText)
        }
    }

    /// One bad phrase must not cost the whole batch.
    private func translateOneByOne(_ batch: [(id: UUID, text: String)], with session: TranslationSession) async {
        for job in batch {
            do {
                let response = try await session.translate(job.text)
                onTranslated?(job.id, response.targetText)
            } catch {
                failedCount += 1
                lastError = error.localizedDescription // shown in the recording and detail headers
            }
        }
    }
}
