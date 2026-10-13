import AVFoundation
import Accelerate
import os

/// Records the microphone into 5-minute parts and hands every buffer to the live transcriber.
///
/// The open part is 16-bit PCM in CAF (`AudioPartFile`): if the app is killed, the next launch
/// repairs it, so a crash loses at most the last unflushed buffer instead of up to five minutes.
/// Each closed part is announced through `partClosedHandler` and transcoded to AAC by the caller.
/// Audio leaves this class as 16 kHz mono Float32, the rate speech models use.
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
    /// A part file was opened (audio thread, or the caller of `start()`).
    var partOpenedHandler: (@Sendable (String) -> Void)?
    /// A part file was closed and is complete on disk (audio thread, or the caller of `stop()`).
    var partClosedHandler: (@Sendable (String) -> Void)?
    /// A write or a restart failed.
    var failureHandler: (@Sendable (String) -> Void)?

    private let folder: URL
    private let framesPerPart: AVAudioFramePosition
    /// Replaced after a media-services reset; touched on the main thread only.
    private var engine = AVAudioEngine()
    private let meterLock = OSAllocatedUnfairLock(initialState: Meter(seconds: 0, level: 0))
    // Guards everything below; the tap thread and stop() both touch the open file.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileName: String?
    private var framesInPart: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var partIndex: Int
    private var isPaused = false
    private var isStopped = false
    private var configurationObserver: NSObjectProtocol?

    init(folder: URL, firstPartIndex: Int = 0, partDuration: TimeInterval = 300) {
        self.folder = folder
        self.partIndex = firstPartIndex
        self.framesPerPart = AVAudioFramePosition(partDuration * Self.sampleRate)
    }

    var meter: Meter { meterLock.withLock { $0 } }

    func start() throws {
        let opened = try lock.withLock { () throws -> String in
            isPaused = false
            isStopped = false
            return try openPartLocked()
        }
        partOpenedHandler?(opened)
        try installTapAndStart()
        observeConfigurationChanges()
    }

    func pause() {
        lock.withLock { isPaused = true }
        engine.pause()
    }

    /// Also used by the stall watchdog: rebuilding the tap is safe while running.
    func resume() throws {
        lock.withLock { isPaused = false }
        // The input format may have changed while paused (a mic plugged in), so rebuild the tap.
        try installTapAndStart()
    }

    /// After `AVAudioSession.mediaServicesWereResetNotification` every audio object is dead:
    /// build a new engine. The open part file and the frame clock carry on.
    func rebuildAfterMediaServicesReset(startRunning: Bool) throws {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = AVAudioEngine()
        observeConfigurationChanges()
        if startRunning { try resume() }
    }

    /// Closes the open part and returns its name, so the caller can transcode it.
    @discardableResult
    func stop() -> String? {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            isStopped = true
            return closePartLocked()
        }
    }

    // MARK: - Engine

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

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
        guard !isStopped, let converted = convert(buffer), converted.frameLength > 0 else {
            lock.unlock()
            return
        }
        let startFrame = totalFrames
        var failure: Error?
        var closed: String?
        var opened: String?
        if file == nil {
            // The last part could not be opened (disk full?): keep trying, the audio matters most.
            do { opened = try openPartLocked() } catch { failure = error }
        }
        do {
            try file?.write(from: converted)
        } catch {
            failure = error
        }
        let frames = AVAudioFramePosition(converted.frameLength)
        totalFrames += frames
        framesInPart += frames
        if framesInPart >= framesPerPart {
            closed = closePartLocked()
            do { opened = try openPartLocked() } catch { failure = error }
        }
        let total = totalFrames
        lock.unlock()

        let level = Self.level(of: converted)
        meterLock.withLock { $0 = Meter(seconds: Double(total) / Self.sampleRate, level: level) }
        bufferHandler?(converted, startFrame)
        if let closed { partClosedHandler?(closed) }
        if let opened { partOpenedHandler?(opened) }
        if let failure, shouldReport() {
            failureHandler?("خطأ في حفظ الصوت: \(failure.localizedDescription)")
        }
    }

    private let reportLock = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// At most one failure banner every 10 seconds.
    private func shouldReport() -> Bool {
        reportLock.withLock { last in
            guard Date().timeIntervalSince(last) > 10 else { return false }
            last = Date()
            return true
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

    // MARK: - Part files (call with `lock` held)

    private func openPartLocked() throws -> String {
        let name = AudioPartFile.name(index: partIndex, ext: AudioPartFile.openExtension)
        file = try AVAudioFile(
            forWriting: folder.appending(path: name),
            settings: AudioPartFile.recordingSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        fileName = name
        partIndex += 1
        framesInPart = 0
        return name
    }

    private func closePartLocked() -> String? {
        let name = fileName
        file?.close()
        file = nil
        fileName = nil
        return name
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
