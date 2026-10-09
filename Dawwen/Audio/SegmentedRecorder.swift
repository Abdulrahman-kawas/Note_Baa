import AVFoundation
import Accelerate
import os

/// Records the microphone into 5-minute AAC parts and hands every buffer to the live transcriber.
///
/// Each closed part is a complete, playable file, so a crash or a dead battery loses at most the
/// part that was open. Audio leaves this class as 16 kHz mono Float32, the rate speech models use.
final class SegmentedRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let pipelineFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    enum RecorderError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "لا يوجد مايكروفون متاح." }
    }

    struct Meter: Sendable {
        var seconds: Double
        var level: Float
    }

    /// Audio thread: every converted buffer, with its first frame in the recording timeline.
    var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioFramePosition) -> Void)?
    /// A new part file was opened (audio thread, or the caller of `start()`).
    var partHandler: (@Sendable (String) -> Void)?
    /// A write or a restart failed.
    var failureHandler: (@Sendable (String) -> Void)?

    private let folder: URL
    private let framesPerPart: AVAudioFramePosition
    private let engine = AVAudioEngine()
    private let meterLock = OSAllocatedUnfairLock(initialState: Meter(seconds: 0, level: 0))
    // Guards everything below; the tap thread and stop() both touch the open file.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var framesInPart: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var partIndex = 0
    private var isPaused = false
    private var configurationObserver: NSObjectProtocol?

    init(folder: URL, partDuration: TimeInterval = 300) {
        self.folder = folder
        self.framesPerPart = AVAudioFramePosition(partDuration * Self.sampleRate)
    }

    var meter: Meter { meterLock.withLock { $0 } }

    func start() throws {
        lock.withLock { isPaused = false }
        try lock.withLock { try openNextPartLocked() }
        try installTapAndStart()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func pause() {
        lock.withLock { isPaused = true }
        engine.pause()
    }

    func resume() throws {
        lock.withLock { isPaused = false }
        // The input format may have changed while paused (a mic plugged in), so rebuild the tap.
        try installTapAndStart()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            file?.close()
            file = nil
        }
    }

    // MARK: - Engine

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noMicrophone }
        input.removeTap(onBus: 0)
        lock.withLock {
            let converter = AVAudioConverter(from: inputFormat, to: Self.pipelineFormat)
            // No priming: keeps sample positions, and therefore timestamps, exact.
            converter?.primeMethod = .none
            self.converter = converter
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// The system stops the engine when the route or format changes (mic plugged or unplugged).
    private func handleConfigurationChange() {
        guard !lock.withLock({ isPaused }) else { return }
        do {
            try installTapAndStart()
        } catch {
            failureHandler?("تعذّرت إعادة تشغيل المايكروفون بعد تغيّر الإعداد: \(error.localizedDescription)")
        }
    }

    // MARK: - Tap thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let converted = convert(buffer), converted.frameLength > 0 else {
            lock.unlock()
            return
        }
        let startFrame = totalFrames
        var failure: Error?
        do {
            try file?.write(from: converted)
        } catch {
            failure = error
        }
        let frames = AVAudioFramePosition(converted.frameLength)
        totalFrames += frames
        framesInPart += frames
        if framesInPart >= framesPerPart {
            do { try openNextPartLocked() } catch { failure = error }
        }
        let total = totalFrames
        lock.unlock()

        let level = Self.level(of: converted)
        meterLock.withLock { $0 = Meter(seconds: Double(total) / Self.sampleRate, level: level) }
        bufferHandler?(converted, startFrame)
        if let failure {
            failureHandler?("خطأ في حفظ الصوت: \(failure.localizedDescription)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.pipelineFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }

    // MARK: - Part files

    /// Call with `lock` held.
    private func openNextPartLocked() throws {
        file?.close()
        file = nil
        let name = String(format: "part-%03d.m4a", partIndex)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        file = try AVAudioFile(
            forWriting: folder.appending(path: name),
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        partIndex += 1
        framesInPart = 0
        partHandler?(name)
    }

    /// 0…1 loudness for the level meter: RMS on a 60 dB scale.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (decibels + 60) / 60))
    }
}
