import AVFoundation

/// The lecture's part files laid end to end, as the player hears them. Cuts out a time range as a
/// standalone PCM file, so a gap can be transcribed without decoding four hours of audio.
struct AudioTimeline: Sendable {
    struct Part: Sendable {
        let url: URL
        let start: Double
        let duration: Double
    }

    let parts: [Part]

    var duration: Double { parts.last.map { $0.start + $0.duration } ?? 0 }

    /// Unreadable parts are skipped, exactly like `LecturePlayer.makeComposition`.
    init(urls: [URL]) {
        var cursor = 0.0
        var parts: [Part] = []
        for url in urls {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            parts.append(Part(url: url, start: cursor, duration: seconds))
            cursor += seconds
        }
        self.parts = parts
    }

    func extract(from start: Double, to end: Double) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "gap-\(UUID().uuidString).caf")
        var writer: AVAudioFile?
        for part in parts where part.start < end && part.start + part.duration > start {
            let file = try AVAudioFile(forReading: part.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            if writer == nil {
                writer = try AVAudioFile(
                    forWriting: output,
                    settings: AudioPartFile.pcmSettings(sampleRate: format.sampleRate, channels: format.channelCount),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            }
            let first = AVAudioFramePosition(max(0, start - part.start) * format.sampleRate)
            let last = min(file.length, AVAudioFramePosition(min(part.duration, end - part.start) * format.sampleRate))
            guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { continue }
            file.framePosition = first
            var remaining = AVAudioFrameCount(last - first)
            while remaining > 0 {
                try file.read(into: buffer, frameCount: min(remaining, buffer.frameCapacity))
                if buffer.frameLength == 0 { break }
                try writer?.write(from: buffer)
                remaining -= min(remaining, buffer.frameLength)
            }
        }
        guard let writer else { throw CocoaError(.fileReadNoSuchFile) }
        writer.close()
        return output
    }
}
