import AVFoundation
import MediaPlayer
import Observation

/// Plays all parts of a lecture as one timeline, so a transcript timestamp maps straight to a seek.
@MainActor
@Observable
final class LecturePlayer {
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1 {
        didSet {
            player?.defaultRate = rate
            if isPlaying { player?.rate = rate }
        }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var title = ""

    /// Joins the part files without re-encoding.
    static func makeComposition(urls: [URL]) async -> (AVMutableComposition, Double) {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return (composition, 0)
        }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            do {
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let range = try await source.load(.timeRange)
                try track.insertTimeRange(range, of: source, at: cursor)
                cursor = cursor + range.duration
            } catch {
                continue // An unreadable part (e.g. cut off by a crash) is skipped.
            }
        }
        let seconds = cursor.seconds
        return (composition, seconds.isFinite ? seconds : 0)
    }

    func load(urls: [URL], title: String = "") async {
        teardown()
        self.title = title
        let (composition, seconds) = await Self.makeComposition(urls: urls)
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        self.player = player
        duration = seconds
        currentTime = 0
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        isReady = seconds > 0
        if isReady { configureRemoteCommands() }
    }

    func play() {
        guard let player else { return }
        try? AudioSessionController.activateForPlayback()
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration))
        currentTime = target
        let tolerance = CMTime(value: 1, timescale: 10)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func teardown() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        isReady = false
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Lock screen and headphone controls

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        // Handlers get only Sendable values (the seek position), then hop to the main actor.
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (Double?) -> Void) {
            let target = command.addTarget { event in
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                Task { @MainActor in action(position) }
                return .success
            }
            commandTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] _ in self?.play() }
        add(center.pauseCommand) { [weak self] _ in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayback() }
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(by: 15) }
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -15) }
        add(center.changePlaybackPositionCommand) { [weak self] position in
            if let position { self?.seek(to: position) }
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard isReady else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title.isEmpty ? "محاضرة" : title,
            MPMediaItemPropertyArtist: "دوّن",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0
        ]
    }
}
