import AVFoundation
import os

/// Sits between the recorder's audio thread and the live transcriber, so recording never waits for
/// transcription. Audio that reaches no transcriber (engine still starting, heat pause, failure,
/// record-only) is tracked as one contiguous stretch and reported as a gap when the stretch ends.
/// Replaces 0.1's `FeedGate`.
final class TranscriberFeed: @unchecked Sendable {
    private struct State: Sendable {
        var transcriber: (any LiveTranscriber)?
        var gateOpen = true
        var missStart: AVAudioFramePosition?
        var missReason: TranscriptGap.Reason = .engineStarting
        var lastFrameEnd: AVAudioFramePosition = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called on the audio thread (or by `close()`); hop to the main actor before touching models.
    var onGap: (@Sendable (TranscriptGap) -> Void)?

    /// Audio thread.
    func feed(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) {
        let frames = AVAudioFramePosition(buffer.frameLength)
        let (target, gap) = state.withLock { s -> ((any LiveTranscriber)?, TranscriptGap?) in
            s.lastFrameEnd = startFrame + frames
            guard let transcriber = s.transcriber, s.gateOpen else {
                if s.missStart == nil { s.missStart = startFrame }
                return (nil, nil)
            }
            var gap: TranscriptGap?
            if let missStart = s.missStart {
                gap = Self.gap(from: missStart, to: startFrame, reason: s.missReason)
                s.missStart = nil
            }
            return (transcriber, gap)
        }
        if let gap { onGap?(gap) }
        target?.append(buffer, startFrame: startFrame)
    }

    func attach(_ transcriber: any LiveTranscriber) {
        state.withLock { $0.transcriber = transcriber }
    }

    func detach(reason: TranscriptGap.Reason) {
        state.withLock { s in
            s.transcriber = nil
            s.missReason = reason
        }
    }

    /// Heat: stop feeding the on-device model without dropping the transcriber.
    func setGate(open: Bool, reason: TranscriptGap.Reason) {
        state.withLock { s in
            s.gateOpen = open
            if !open { s.missReason = reason }
        }
    }

    /// End of recording: the stretch still open (if any) becomes a gap.
    func close() -> TranscriptGap? {
        state.withLock { s -> TranscriptGap? in
            defer { s.missStart = nil }
            guard let missStart = s.missStart else { return nil }
            return Self.gap(from: missStart, to: s.lastFrameEnd, reason: s.missReason)
        }
    }

    private static func gap(from start: AVAudioFramePosition, to end: AVAudioFramePosition, reason: TranscriptGap.Reason) -> TranscriptGap {
        TranscriptGap(
            start: Double(start) / SegmentedRecorder.sampleRate,
            end: Double(end) / SegmentedRecorder.sampleRate,
            reason: reason
        )
    }
}
