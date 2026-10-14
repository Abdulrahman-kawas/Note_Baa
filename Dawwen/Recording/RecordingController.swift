import AVFoundation
import Observation
import Speech
import SwiftData
import Translation
import UIKit
import os

/// Runs one lecture: microphone → part files + live transcriber → SwiftData + translation.
///
/// Rules: the recorder starts first and never waits for anything else; whatever audio the
/// transcriber misses becomes a recorded gap that the detail view can fill later; any stop the
/// student did not ask for is retried and, failing that, announced with a notification.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case paused(String)
        case finishing
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var partialText = ""
    private(set) var engineName = ""
    private(set) var banner: String?
    private(set) var lecture: Lecture?
    private(set) var liveSegments: [TranscriptSegment] = []
    /// Set only when the language pair is not installed: the view's `.translationTask` then asks
    /// to download it (the direct session can't).
    private(set) var translationConfiguration: TranslationSession.Configuration?
    /// Seconds of audio with no live transcript so far (shown in the header).
    private(set) var gapSeconds: Double = 0

    @ObservationIgnored let translationQueue = TranslationQueue()
    @ObservationIgnored private var recorder: SegmentedRecorder?
    @ObservationIgnored private var transcriber: (any LiveTranscriber)?
    @ObservationIgnored private let feed = TranscriberFeed()
    @ObservationIgnored private let liveActivity = LectureActivityController()
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var transcodes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var segmentsByID: [UUID: TranscriptSegment] = [:]
    @ObservationIgnored private let audioSession = AudioSessionController()
    @ObservationIgnored private var suspendedForHeat = false
    @ObservationIgnored private var pausedByInterruption = false
    @ObservationIgnored private var allowBluetooth = false
    @ObservationIgnored private var lastProgressSeconds: Double = -1
    @ObservationIgnored private var lastProgressAt = Date()
    @ObservationIgnored private var stallAttempts = 0
    @ObservationIgnored private var meterTicks = 0

    /// One recording at a time, even with two windows of the app open.
    private static var activeRecording: ObjectIdentifier?
    private static let log = Logger(subsystem: "com.dawwen", category: "recording")

    var isActive: Bool {
        switch phase {
        case .recording, .paused, .preparing: true
        default: false
        }
    }

    private var isRecordingSession: Bool {
        switch phase {
        case .recording, .paused: true
        default: false
        }
    }

    // MARK: - Start

    func start(_ request: NewLectureRequest, context: ModelContext) async {
        guard phase == .idle else { return }
        guard Self.activeRecording == nil else {
            phase = .failed("A recording is already running in another window. Finish it first.")
            return
        }
        Self.activeRecording = ObjectIdentifier(self)
        self.context = context
        let settings = AppSettings.current
        allowBluetooth = settings.allowBluetoothMic

        phase = .preparing("Requesting microphone permission…")
        guard await AVAudioApplication.requestRecordPermission() else {
            fail("Microphone access isn't allowed. Turn it on in Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }
        guard phase != .finished, phase != .finishing else { return } // the view went away meanwhile
        if let storage = StorageGuard.status() {
            if storage.isCritical {
                fail("Only \(storage.description) free. Delete some files and try again.")
                return
            }
            if storage.isLow { banner = "Storage is low (\(storage.description))." }
        }

        // The microphone starts now. The engine is resolved and prepared afterwards, in parallel.
        let lecture = Lecture(title: request.title, sourceLanguage: request.language, targetLanguage: request.targetLanguage, engine: request.engine)
        do {
            try LectureStore.createFolder(for: lecture.id)
        } catch {
            fail("Couldn't create the lecture folder: \(error.localizedDescription)")
            return
        }
        context.insert(lecture)
        save()
        self.lecture = lecture
        do {
            try startRecorder(for: lecture)
        } catch {
            lecture.status = .interrupted
            save()
            fail("Couldn't start recording: \(error.localizedDescription)")
            return
        }

        audioSession.onInterruptionBegan = { [weak self] in self?.interruptionBegan() }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in self?.interruptionEnded(shouldResume: shouldResume) }
        audioSession.onMediaServicesReset = { [weak self] in self?.mediaServicesWereReset() }
        audioSession.startObserving()
        observeThermalState()
        warnIfBatteryLow()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        startMeter()
        phase = .recording
        liveActivity.start(title: request.title, startedAt: .now)
        engineName = "Preparing transcription…"

        Task { await RecordingAlerts.requestAuthorization() }
        configureTranslation(source: request.language, target: request.targetLanguage)
        engineTask = Task { [weak self] in
            await self?.attachTranscriber(request, vocabulary: settings.vocabulary)
        }
    }

    private func attachTranscriber(_ request: NewLectureRequest, vocabulary: [String]) async {
        let kind = await TranscriberFactory.resolve(
            request.engine, language: request.language, hasSonioxKey: SonioxCredentials.isConfigured
        )
        guard isRecordingSession, let lecture else { return }
        lecture.engineRaw = kind.rawValue
        save()
        guard kind != .none else {
            engineName = EngineKind.none.title
            feed.detach(reason: .recordOnly)
            return
        }
        if kind == .apple {
            // SpeechAnalyzer transcribed without this permission in testing; asking once is cheap.
            _ = await Self.requestSpeechAuthorization()
        }
        var created: (any LiveTranscriber)?
        do {
            guard let transcriber = try TranscriberFactory.make(
                kind, language: request.language, vocabulary: vocabulary, translationTarget: request.targetLanguage
            ) else { return }
            created = transcriber
            consumeEvents(of: transcriber)
            try await transcriber.start()   // may download the language model the first time
            guard isRecordingSession else {
                await transcriber.finish()
                return
            }
            self.transcriber = transcriber
            engineName = transcriber.displayName
            feed.attach(transcriber)
            evaluateThermalState()
        } catch {
            await created?.finish()
            banner = "Couldn't start live transcription: \(error.localizedDescription) Recording continues, and the untranscribed part is filled in from the audio after the lecture."
            engineName = EngineKind.none.title
            feed.detach(reason: .engineFailed)
        }
    }

    private func configureTranslation(source: String, target: String?) {
        guard let target, Languages.code(target) != Languages.code(source) else { return }
        translationQueue.onTranslated = { [weak self] id, text in
            guard let self, let segment = self.segmentsByID[id] else { return }
            segment.translation = text
            self.save()
        }
        let queue = translationQueue
        translationTask = Task { [weak self] in
            // Installed languages: a session that needs no view, keeps going with the screen locked
            // (measure on device), and never shows a download prompt in the middle of a lecture.
            if let session = await TranslationSupport.installedSession(source: source, target: target, purpose: .live) {
                await queue.run(with: session)
            } else {
                self?.banner = "The translation language isn't downloaded on this device. Download it in Settings before the next lecture; you'll be asked to download it now."
                self?.translationConfiguration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: source), target: Locale.Language(identifier: target)
                )
            }
        }
    }

    private func startRecorder(for lecture: Lecture) throws {
        try AudioSessionController.activateForRecording(allowBluetooth: allowBluetooth)
        let recorder = SegmentedRecorder(folder: LectureStore.folder(for: lecture.id))
        let feed = feed
        recorder.bufferHandler = { buffer, startFrame in
            feed.feed(buffer, startFrame: startFrame)
        }
        feed.onGap = { [weak self] gap in
            Task { @MainActor in self?.recordGap(gap) }
        }
        recorder.partOpenedHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshParts() }
        }
        recorder.partClosedHandler = { [weak self] name in
            Task { @MainActor in self?.archivePart(name) }
        }
        recorder.failureHandler = { [weak self] message in
            Task { @MainActor in self?.banner = message }
        }
        try recorder.start()
        self.recorder = recorder
    }

    // MARK: - Controls

    func pause() {
        guard phase == .recording else { return }
        recorder?.pause()
        pausedByInterruption = false
        phase = .paused("Paused")
        liveActivity.setPaused(true)
    }

    func resume() {
        guard case .paused = phase else { return }
        resumeRecording()
    }

    @discardableResult
    private func resumeRecording() -> Bool {
        guard let recorder else { return false }
        do {
            try AudioSessionController.activateForRecording(allowBluetooth: allowBluetooth)
            try recorder.resume()
            phase = .recording
            liveActivity.setPaused(false)
            pausedByInterruption = false
            lastProgressAt = .now
            return true
        } catch {
            banner = "Couldn't resume: \(error.localizedDescription)"
            return false
        }
    }

    /// Adds text read from a slide, timed at the current point in the recording.
    func addSlideText(_ lines: [String]) {
        guard let lecture, isActive else { return }
        let texts = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        for text in texts {
            let segment = TranscriptSegment(start: elapsed, end: elapsed, text: text, speaker: "Slide")
            context?.insert(segment)
            segment.lecture = lecture
            liveSegments.append(segment)
            segmentsByID[segment.uid] = segment
        }
        save()
        banner = "Added \(texts.count) text blocks from the slide at \(TimeFormat.clock(elapsed))"
    }

    func addBookmark() {
        guard let lecture else { return }
        lecture.bookmarks.append(elapsed)
        save()
        banner = "Bookmark added at \(TimeFormat.clock(elapsed))"
    }

    func stop() async {
        guard isActive else { return }
        guard let lecture else {
            // Stopped while still asking for permission: nothing was recorded.
            phase = .finished
            liveActivity.end()
            releaseLock()
            return
        }
        phase = .finishing
        meterTask?.cancel()
        engineTask?.cancel()
        let lastPart = recorder?.stop()
        let duration = recorder?.meter.seconds ?? elapsed
        if let gap = feed.close() { recordGap(gap) }
        feed.detach(reason: .unknown)
        if let transcriber {
            await transcriber.finish()
            await eventsTask?.value
        }
        partialText = ""
        if let lastPart { archivePart(lastPart) }
        for task in Array(transcodes.values) { await task.value }
        lecture.duration = duration
        lecture.audioSegments = LectureStore.partFileNames(in: LectureStore.folder(for: lecture.id))
        lecture.status = .ready
        save()
        tearDownObservers()
        translationQueue.finishWhenDrained()
        phase = .finished
        liveActivity.end()
        try? LectureArchive.write(lecture)
        BackupUploader.shared.enqueue(lecture, includeArchive: true)
    }

    /// The recording screen is going away. Finish what was recorded; stop translating (what is
    /// left is picked up automatically when the lecture is opened).
    func dismantle() {
        let translation = translationTask
        if isActive {
            Task {
                await stop()
                translation?.cancel()
            }
        } else {
            translation?.cancel()
        }
    }

    // MARK: - Parts

    private func refreshParts() {
        guard let lecture else { return }
        lecture.audioSegments = LectureStore.partFileNames(in: LectureStore.folder(for: lecture.id))
        save()
    }

    /// A closed PCM part becomes AAC off the main thread. If that fails, the CAF stays: it plays
    /// and backs up like any other part.
    private func archivePart(_ name: String) {
        guard let lecture, transcodes[name] == nil else { return }
        let url = LectureStore.folder(for: lecture.id).appending(path: name)
        transcodes[name] = Task { [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try AudioPartFile.transcodeToAAC(url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.transcodes[name] = nil
            if let failure { Self.log.error("transcode \(name, privacy: .public) failed: \(failure, privacy: .public)") }
            self.refreshParts()
            if let lecture = self.lecture { BackupUploader.shared.enqueue(lecture, includeArchive: false) }
        }
    }

    // MARK: - Events

    private func consumeEvents(of transcriber: any LiveTranscriber) {
        eventsTask = Task { [weak self] in
            for await event in transcriber.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let text):
            partialText = text
        case .final(let text, let start, let end, let speaker):
            guard let lecture, let context else { return }
            let segment = TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
            context.insert(segment)
            segment.lecture = lecture
            liveSegments.append(segment)
            segmentsByID[segment.uid] = segment
            save() // Every confirmed phrase is on disk at once.
            if lecture.targetLanguage != nil, translationQueue.onTranslated != nil {
                translationQueue.enqueue(id: segment.uid, text: text)
            }
        case .gap(let start, let end):
            let reason: TranscriptGap.Reason = transcriber?.runsOnDevice == false ? .network : .overload
            recordGap(TranscriptGap(start: start, end: end, reason: reason))
        case .status(let message):
            banner = message.isEmpty ? nil : message
        case .failure(let message):
            banner = "Live transcription stopped: \(message) Recording continues, and the untranscribed part is filled in from the audio after the lecture."
            feed.detach(reason: .engineFailed)
            lecture?.transcriptionIncomplete = true
            save()
        }
    }

    private func recordGap(_ gap: TranscriptGap) {
        guard let lecture else { return }
        lecture.addGap(gap)
        gapSeconds = lecture.untranscribedSeconds
        save()
    }

    // MARK: - Interruptions, media reset, stalls

    private func interruptionBegan() {
        guard phase == .recording else { return }
        recorder?.pause()
        pausedByInterruption = true
        phase = .paused("Recording paused because of an interruption (a call or another app).")
        liveActivity.setPaused(true)
    }

    /// A recorder must come back even without `.shouldResume`: try, then tell the student.
    private func interruptionEnded(shouldResume: Bool) {
        guard case .paused = phase, pausedByInterruption else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(shouldResume ? 200 : 800))
            guard let self, case .paused = self.phase, self.pausedByInterruption else { return }
            if !self.resumeRecording() {
                RecordingAlerts.post("Recording paused", "The interruption ended but recording didn't resume. Open Dawwen and tap Resume.")
            }
        }
    }

    /// Apple's general advice is to wait for the user after a media-server reset; a lecture the
    /// student already started is that user action, so the recorder is rebuilt and restarted.
    private func mediaServicesWereReset() {
        guard isRecordingSession, let recorder else { return }
        let wasRecording = phase == .recording
        do {
            try AudioSessionController.activateForRecording(allowBluetooth: allowBluetooth)
            try recorder.rebuildAfterMediaServicesReset(startRunning: wasRecording)
            banner = "The system restarted its audio services, and recording continued."
        } catch {
            phase = .paused("The system's audio services stopped. Tap Resume.")
            liveActivity.setPaused(true)
            pausedByInterruption = false
            RecordingAlerts.post("Recording paused", "The system restarted its audio services. Open Dawwen and tap Resume.")
        }
    }

    private func startMeter() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let recorder = self.recorder else { return }
                let meter = recorder.meter
                self.elapsed = meter.seconds
                self.level = meter.level
                self.watchdog(seconds: meter.seconds)
            }
        }
    }

    /// No new audio for 5 s while "recording" means the engine died silently: restart it.
    private func watchdog(seconds: Double) {
        meterTicks += 1
        if meterTicks % 240 == 0 { checkStorage() } // once a minute
        guard phase == .recording else {
            lastProgressAt = .now
            return
        }
        if seconds > lastProgressSeconds {
            lastProgressSeconds = seconds
            lastProgressAt = .now
            stallAttempts = 0
            return
        }
        guard Date.now.timeIntervalSince(lastProgressAt) > 5 else { return }
        stallAttempts += 1
        lastProgressAt = .now
        Self.log.error("no audio for 5 s, restart attempt \(self.stallAttempts)")
        let restarted = resumeRecording()
        banner = restarted ? "Audio dropped for a moment and the microphone was restarted." : "No sound is coming from the microphone."
        if !restarted || stallAttempts >= 2 {
            RecordingAlerts.post("Check the recording", "No sound has come from the microphone for a few seconds.")
        }
    }

    private func checkStorage() {
        guard let storage = StorageGuard.status() else { return }
        if storage.freeBytes < 100_000_000 {
            banner = "The device is almost full; recording ended and everything recorded was saved."
            RecordingAlerts.post("Recording ended", "The device is full. Everything recorded so far was saved.")
            Task { await stop() }
        } else if storage.isCritical {
            banner = "Only \(storage.description) free."
        }
    }

    // MARK: - Heat, battery

    private func observeThermalState() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateThermalState() }
        }
        evaluateThermalState()
    }

    /// On-device models heat the iPad. Above `.serious` we stop feeding them; recording continues.
    private func evaluateThermalState() {
        guard transcriber?.runsOnDevice == true else { return }
        let state = ProcessInfo.processInfo.thermalState
        if state == .serious || state == .critical {
            guard !suspendedForHeat else { return }
            suspendedForHeat = true
            feed.setGate(open: false, reason: .heat)
            banner = "The device is hot: live transcription is paused, and recording continues."
        } else if suspendedForHeat, state == .nominal || state == .fair {
            suspendedForHeat = false
            feed.setGate(open: true, reason: .heat)
            banner = "Live transcription is back. The missed part is filled in from the audio after the lecture."
        }
    }

    private func warnIfBatteryLow() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.2 {
            banner = "Battery is below 20%. Plug in the charger before a long lecture."
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        phase = .failed(message)
        tearDownObservers()
    }

    private func save() {
        guard let context else { return }
        do {
            try context.save()
        } catch {
            Self.log.error("save failed: \(error.localizedDescription, privacy: .public)")
            banner = "Couldn't save the latest changes: \(error.localizedDescription)"
        }
    }

    private func releaseLock() {
        if Self.activeRecording == ObjectIdentifier(self) { Self.activeRecording = nil }
    }

    private func tearDownObservers() {
        audioSession.stopObserving()
        AudioSessionController.deactivate()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        UIApplication.shared.isIdleTimerDisabled = false
        releaseLock()
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

struct NewLectureRequest: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var language: String
    var targetLanguage: String?
    var engine: EngineKind
}
