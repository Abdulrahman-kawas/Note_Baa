import AVFoundation
import SwiftData

/// Transcribes only the audio that has no text yet, from the recorded parts, and slots the new
/// phrases in. Never touches existing phrases, their translations or speaker labels (0.1 replaced
/// the whole transcript).
@MainActor
enum GapFiller {
    static func fill(
        _ lecture: Lecture,
        context: ModelContext,
        progress: @escaping BackgroundWork.ProgressHandler
    ) async throws -> Int {
        var gaps = lecture.gaps
        if gaps.isEmpty {
            // Lectures from 0.1 have no gap list: look for long silences in the transcript instead.
            gaps = GapMath.inferred(from: lecture.sortedSegments.map { ($0.start, $0.end) }, duration: lecture.duration)
        }
        guard !gaps.isEmpty else {
            lecture.transcriptionIncomplete = false
            try context.save()
            return 0
        }
        let urls = LectureStore.audioURLs(for: lecture)
        let timeline = await Task.detached(priority: .utility) { AudioTimeline(urls: urls) }.value
        let language = lecture.sourceLanguage
        let vocabulary = AppSettings.current.vocabulary
        let windows = gaps.flatMap { gap in GapMath.windows(of: gap).map { (gap: gap, window: $0) } }
        var added: [TranscriptSegment] = []

        for (index, item) in windows.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(windows.count), "Untranscribed audio: \(index + 1) of \(windows.count)")
            // 1.5 s of padding gives the model whole words at the edges; phrases whose middle
            // falls in the padding belong to the neighbouring text and are dropped.
            let paddedStart = max(0, item.window.start - 1.5)
            let paddedEnd = min(timeline.duration, item.window.end + 1.5)
            guard paddedEnd - paddedStart > 0.5 else { continue }
            let slice = try await Task.detached(priority: .utility) {
                try timeline.extract(from: paddedStart, to: paddedEnd)
            }.value
            defer { try? FileManager.default.removeItem(at: slice) }

            let pieces = try await FileTranscriber.transcribe(urls: [slice], language: language, vocabulary: vocabulary) { _ in }
            for piece in pieces {
                let start = paddedStart + piece.start
                let end = paddedStart + piece.end
                let middle = (start + end) / 2
                guard middle >= item.window.start, middle < item.window.end else { continue }
                let segment = TranscriptSegment(start: start, end: end, text: piece.text)
                context.insert(segment)
                segment.lecture = lecture
                added.append(segment)
            }
            if item.window.end >= item.gap.end - 0.01 {
                lecture.clearGaps(within: item.gap.start, item.gap.end)
            }
            try context.save()
        }
        lecture.transcriptionIncomplete = !lecture.gaps.isEmpty
        try context.save()

        if let target = lecture.targetLanguage, !added.isEmpty,
           let session = await TranslationSupport.installedSession(source: language, target: target, purpose: .document) {
            progress(1, "Translating the added sentences…")
            try await TranslationSupport.translate(added, with: session)
            try context.save()
        }
        try? LectureArchive.write(lecture)
        return added.count
    }
}
