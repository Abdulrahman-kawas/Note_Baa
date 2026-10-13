import AVFoundation

/// Part files on disk. While a part is open it is 16-bit PCM in CAF: unlike AAC in MP4, whose index
/// is written only on close, a CAF cut off by a crash can be repaired. Closed parts are transcoded
/// to AAC m4a (~1.2 MB per 5 minutes) off the audio thread.
enum AudioPartFile {
    static let openExtension = "caf"
    static let archiveExtension = "m4a"

    static func pcmSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    static var recordingSettings: [String: Any] {
        pcmSettings(sampleRate: SegmentedRecorder.sampleRate, channels: 1)
    }

    static func aacSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 32_000
        ]
    }

    static func name(index: Int, ext: String) -> String {
        String(format: "part-%03d.%@", index, ext)
    }

    /// "part-012.caf" → 12. Temporary transcodes ("part-012.tmp.m4a") are not parts.
    static func index(of name: String) -> Int? {
        guard name.hasPrefix("part-"), !name.contains(".tmp.") else { return nil }
        let digits = name.dropFirst(5).prefix { $0.isNumber }
        return Int(digits)
    }

    static func isPart(_ name: String) -> Bool {
        index(of: name) != nil && (name.hasSuffix(".\(openExtension)") || name.hasSuffix(".\(archiveExtension)"))
    }

    /// Transcodes a closed PCM part to AAC beside it, checks the result, then deletes the PCM.
    /// The m4a appears under its final name only once complete. Returns nil for an empty part.
    @discardableResult
    static func transcodeToAAC(_ source: URL) throws -> URL? {
        let fileManager = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let folder = source.deletingLastPathComponent()
        let destination = folder.appending(path: "\(base).\(archiveExtension)")
        let temporary = folder.appending(path: "\(base).tmp.\(archiveExtension)")
        try? fileManager.removeItem(at: temporary)

        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputLength = input.length
        guard inputLength > 0 else {
            try? fileManager.removeItem(at: source)
            return nil
        }
        let format = input.processingFormat
        do {
            let output = try AVAudioFile(
                forWriting: temporary,
                settings: aacSettings(sampleRate: format.sampleRate, channels: format.channelCount),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
                throw CocoaError(.fileReadUnknown)
            }
            while input.framePosition < inputLength {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            output.close()
        }
        input.close()
        let check = try AVAudioFile(forReading: temporary)
        // AAC priming can shift the length by a few milliseconds; anything bigger is a failed encode.
        guard abs(check.length - inputLength) < AVAudioFramePosition(format.sampleRate) else {
            try? fileManager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        try fileManager.removeItem(at: source)
        return destination
    }

    /// Makes a CAF whose writer died readable again: sets the `data` chunk size to what is really
    /// on disk (whole frames only). Returns true when the file was changed.
    @discardableResult
    static func repairCAF(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 8), header.count == 8,
              header.prefix(4).elementsEqual("caff".utf8) else { return false }

        var offset: UInt64 = 8
        var bytesPerFrame: UInt64 = 2
        while offset + 12 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunkHeader = try handle.read(upToCount: 12), chunkHeader.count == 12 else { return false }
            let type = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let size = Int64(bitPattern: chunkHeader.dropFirst(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            let payload = offset + 12

            if type == "desc", size >= 32 {
                // AudioStreamBasicDescription, big-endian: mBytesPerPacket sits at byte 12.
                try handle.seek(toOffset: payload + 12)
                if let raw = try handle.read(upToCount: 4), raw.count == 4 {
                    let value = raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    if value > 0 { bytesPerFrame = value }
                }
            }

            if type == "data" {
                let onDisk = fileSize - payload
                guard onDisk >= 4 else { return false }          // 4-byte edit count comes first
                let audioBytes = (onDisk - 4) / bytesPerFrame * bytesPerFrame
                let wanted = 4 + audioBytes
                if size == Int64(wanted) { return false }
                var bigEndian = wanted.bigEndian
                let bytes = withUnsafeBytes(of: &bigEndian) { Data($0) }
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: bytes)
                if fileSize > payload + wanted {
                    try handle.truncate(atOffset: payload + wanted)
                }
                return true
            }
            guard size >= 0 else { return false }
            offset = payload + UInt64(size)
        }
        return false
    }
}
