import AVFoundation

/// Owns the shared AVAudioSession: category per use, plus interruption and media-reset events.
@MainActor
final class AudioSessionController {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// The media server restarted: every audio object must be rebuilt.
    var onMediaServicesReset: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    /// `.record` takes the built-in, wired or USB-C microphone; a clip-on wireless mic's USB-C
    /// receiver shows up as USB and needs nothing more. Bluetooth HFP is narrow-band (8–16 kHz) and
    /// hurts recognition, so it is opt-in (Settings ▸ While recording).
    static func activateForRecording(allowBluetooth: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: allowBluetooth ? [.allowBluetoothHFP] : [])
        try session.setActive(true)
    }

    static func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startObserving() {
        stopObserving()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        })
        // Posted on the main thread; no userInfo.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMediaServicesReset?() }
        })
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func handleInterruption(_ info: [AnyHashable: Any]) {
        guard let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            onInterruptionEnded?(AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume))
        @unknown default:
            break
        }
    }
}
