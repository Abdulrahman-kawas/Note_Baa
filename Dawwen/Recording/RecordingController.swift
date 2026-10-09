import AVFoundation
import Observation
import Speech
import SwiftData
import Translation
import UIKit
import os

/// Runs one lecture: microphone → part files + live transcriber → SwiftData + translation.
/// Recording never depends on transcription: if the transcriber fails, recording continues.
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
    private(set) var translationConfiguration: TranslationSession.Configuration?

    @ObservationIgnored let translationQueue = TranslationQueue()
    @ObservationIgnored private var recorder: SegmentedRecorder?
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var segmentsByID: [UUID: TranscriptSegment] = [:]
    @ObservationIgnored private let audioSession = AudioSessionController()
    @ObservationIgnored private let feedGate = FeedGate()
    @ObservationIgnored private var suspendedForHeat = false

    var isActive: Bool {
        switch phase {
        case .recording, .paused, .preparing: true
        default: false
        }
    }

    // MARK: - Start

    func start(_ request: NewLectureRequest, context: ModelContext) async {
        guard phase == .idle else { return }
        self.context = context
        let settings = AppSettings.current

        phase = .preparing("طلب إذن المايكروفون…")
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("لم يُسمح باستخدام المايكروفون. فعّله من الإعدادات ← الخصوصية ← المايكروفون.")
            return
        }

        let kind = await TranscriberFactory.resolve(
            request.engine, language: request.language, hasSonioxKey: KeychainStore.read(.soniox) != nil
        )
        if kind == .apple {
            // SpeechAnalyzer transcribed without this permission in testing (macOS 26.5). Asking once
            // costs a dialog; a refusal is not treated as fatal, the engine reports any real failure.
            _ = await Self.requestSpeechAuthorization()
        }

        let lecture = Lecture(title: request.title, sourceLanguage: request.language, targetLanguage: request.targetLanguage, engine: kind)
        do {
            try LectureStore.createFolder(for: lecture.id)
        } catch {
            phase = .failed("تعذّر إنشاء مجلد المحاضرة: \(error.localizedDescription)")
            return
        }
        context.insert(lecture)
        try? context.save()
        self.lecture = lecture

        await startTranscriber(kind, request: request, vocabulary: settings.vocabulary)
        configureTranslation(source: request.language, target: request.targetLanguage)

        do {
            try startRecorder(for: lecture)
        } catch {
            phase = .failed("تعذّر بدء التسجيل: \(error.localizedDescription)")
            await transcriber?.finish()
            lecture.status = .interrupted
            try? context.save()
            return
        }

        audioSession.onInterruptionBegan = { [weak self] in self?.interruptionBegan() }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in self?.interruptionEnded(shouldResume: shouldResume) }
        audioSession.startObserving()
        observeThermalState()
        warnIfBatteryLow()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        startMeter()
        phase = .recording
    }

    private func startTranscriber(_ kind: EngineKind, request: NewLectureRequest, vocabulary: [String]) async {
        guard kind != .none else {
            engineName = EngineKind.none.title
            lecture?.transcriptionIncomplete = true
            return
        }
        phase = .preparing("تجهيز محرك التفريغ…")
        do {
            guard let transcriber = try TranscriberFactory.make(kind, language: request.language, vocabulary: vocabulary) else { return }
            try await transcriber.start()
            self.transcriber = transcriber
            engineName = transcriber.displayName
            consumeEvents(of: transcriber)
        } catch {
            banner = "تعذّر تشغيل التفريغ اللحظي: \(error.localizedDescription) التسجيل يعمل، ويمكن التفريغ من الصوت لاحقاً."
            engineName = EngineKind.none.title
            lecture?.transcriptionIncomplete = true
        }
    }

    private func configureTranslation(source: String, target: String?) {
        guard let target, Languages.code(target) != Languages.code(source) else { return }
        translationQueue.onTranslated = { [weak self] id, text in
            guard let self, let segment = self.segmentsByID[id] else { return }
            segment.translation = text
            try? self.context?.save()
        }
        translationConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
    }

    private func startRecorder(for lecture: Lecture) throws {
        try AudioSessionController.activateForRecording()
        let recorder = SegmentedRecorder(folder: LectureStore.folder(for: lecture.id))
        let gate = feedGate
        let transcriber = transcriber
        recorder.bufferHandler = { buffer, startFrame in
            guard gate.isOpen else { return }
            transcriber?.append(buffer, startFrame: startFrame)
        }
        recorder.partHandler = { [weak self] name in
            Task { @MainActor in
                guard let self, let lecture = self.lecture else { return }
                lecture.audioSegments.append(name)
                try? self.context?.save()
            }
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
        phase = .paused("متوقف مؤقتاً")
    }

    func resume() {
        guard case .paused = phase, let recorder else { return }
        do {
            try AudioSessionController.activateForRecording()
            try recorder.resume()
            phase = .recording
        } catch {
            banner = "تعذّر الاستئناف: \(error.localizedDescription)"
        }
    }

    func addBookmark() {
        guard let lecture else { return }
        lecture.bookmarks.append(elapsed)
        try? context?.save()
        banner = "أُضيفت علامة عند \(TimeFormat.clock(elapsed))"
    }

    func stop() async {
        guard isActive, let lecture else { return }
        phase = .finishing
        meterTask?.cancel()
        recorder?.stop()
        let duration = recorder?.meter.seconds ?? elapsed
        if let transcriber {
            await transcriber.finish()
            await eventsTask?.value
        }
        partialText = ""
        lecture.duration = duration
        lecture.audioSegments = LectureStore.partFileNames(in: LectureStore.folder(for: lecture.id))
        lecture.status = .ready
        try? context?.save()
        tearDownObservers()
        phase = .finished
    }

    /// Called if the view goes away while recording; saves what exists.
    func abandon() {
        guard isActive else { return }
        Task { await stop() }
    }

    // MARK: - Events

    private func consumeEvents(of transcriber: LiveTranscriber) {
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
            try? context.save() // Every confirmed phrase is on disk at once.
            if translationConfiguration != nil {
                translationQueue.enqueue(id: segment.uid, text: text)
            }
        case .status(let message):
            banner = message.isEmpty ? nil : message
        case .failure(let message):
            banner = "توقف التفريغ اللحظي: \(message) التسجيل مستمر، ويمكن إكمال النص من الصوت بعد المحاضرة."
            lecture?.transcriptionIncomplete = true
        }
    }

    // MARK: - Interruptions, heat, battery

    private func interruptionBegan() {
        guard phase == .recording else { return }
        recorder?.pause()
        phase = .paused("أُوقف التسجيل مؤقتاً بسبب مقاطعة (مكالمة أو تطبيق آخر).")
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard case .paused = phase else { return }
        if shouldResume { resume() }
    }

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
            feedGate.isOpen = false
            lecture?.transcriptionIncomplete = true
            banner = "حرارة الجهاز مرتفعة: أوقفنا التفريغ اللحظي مؤقتاً، والتسجيل مستمر."
        } else if suspendedForHeat, state == .nominal || state == .fair {
            suspendedForHeat = false
            feedGate.isOpen = true
            banner = "عاد التفريغ اللحظي. الجزء الفائت يُستكمل من الصوت بعد المحاضرة."
        }
    }

    private func warnIfBatteryLow() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.2 {
            banner = "البطارية أقل من 20%. صِل الشاحن قبل محاضرة طويلة."
        }
    }

    private func startMeter() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder else { return }
                let meter = recorder.meter
                self.elapsed = meter.seconds
                self.level = meter.level
            }
        }
    }

    private func tearDownObservers() {
        audioSession.stopObserving()
        AudioSessionController.deactivate()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

/// Lets the audio thread skip the transcriber (heat) without touching the main actor.
final class FeedGate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)

    var isOpen: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

struct NewLectureRequest: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var language: String
    var targetLanguage: String?
    var engine: EngineKind
}
