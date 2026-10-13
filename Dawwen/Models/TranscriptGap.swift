import Foundation

/// A stretch of recorded audio that has no transcript (yet). The audio itself is always on disk.
struct TranscriptGap: Codable, Hashable, Sendable {
    enum Reason: String, Codable, Sendable {
        case engineStarting   // the recorder started before the engine was ready
        case recordOnly       // the student chose "record only"
        case heat             // on-device engine paused at .serious thermal state
        case network          // Soniox could not keep up / was offline
        case overload         // on-device analyzer fell behind and dropped audio
        case engineFailed
        case crash            // the app died; text after the last saved phrase is missing
        case unknown
    }

    var start: Double
    var end: Double
    var reason: Reason

    var duration: Double { max(0, end - start) }
}

enum GapMath {
    /// Sorted and merged: gaps closer than `joinWithin` seconds become one.
    static func merged(_ gaps: [TranscriptGap], joinWithin: Double = 1) -> [TranscriptGap] {
        let sorted = gaps.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [TranscriptGap] = []
        for gap in sorted {
            if var last = result.last, gap.start <= last.end + joinWithin {
                last.end = max(last.end, gap.end)
                result[result.count - 1] = last
            } else {
                result.append(gap)
            }
        }
        return result
    }

    /// For lectures from version 0.1 (no gap list): long silences in the transcript, plus the
    /// head and tail of the recording.
    static func inferred(from segments: [(start: Double, end: Double)], duration: Double, minimum: Double = 20) -> [TranscriptGap] {
        guard duration > 0 else { return [] }
        guard !segments.isEmpty else { return [TranscriptGap(start: 0, end: duration, reason: .unknown)] }
        var gaps: [TranscriptGap] = []
        var cursor = 0.0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if segment.start - cursor >= minimum {
                gaps.append(TranscriptGap(start: cursor, end: segment.start, reason: .unknown))
            }
            cursor = max(cursor, segment.end)
        }
        if duration - cursor >= minimum {
            gaps.append(TranscriptGap(start: cursor, end: duration, reason: .unknown))
        }
        return gaps
    }

    /// Splits a long gap so each file-transcription pass stays small (10 minutes by default).
    static func windows(of gap: TranscriptGap, maxLength: Double = 600) -> [TranscriptGap] {
        guard gap.duration > maxLength else { return [gap] }
        var windows: [TranscriptGap] = []
        var start = gap.start
        while start < gap.end {
            let end = min(gap.end, start + maxLength)
            windows.append(TranscriptGap(start: start, end: end, reason: gap.reason))
            start = end
        }
        return windows
    }
}
