import SwiftData
import SwiftUI
import Translation

struct LectureDetailView: View {
    @Bindable var lecture: Lecture

    @Environment(\.modelContext) private var context
    @State private var player = LecturePlayer()
    @State private var summaryJob = SummaryJob()
    @State private var askSession = AskSession()
    @State private var translationQueue = TranslationQueue()
    /// Fallback only: languages not installed → `.translationTask` asks to download them.
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var tab: DetailTab = .transcript
    @State private var showTranslation = true
    @State private var status: String?
    @State private var confirmRetranscribe = false
    @State private var showRename = false
    @State private var draftTitle = ""

    private var work: BackgroundWork { BackgroundWork.shared }
    private var isWorking: Bool { work.running.contains(lecture.id) }

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript, summary, ask, bookmarks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: "النص"
            case .summary: "الملخص"
            case .ask: "اسأل"
            case .bookmarks: "العلامات"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("القسم", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            infoLine

            if lecture.transcriptionIncomplete && !isWorking {
                incompleteBanner
            }

            Group {
                switch tab {
                case .transcript:
                    TranscriptListView(lecture: lecture, player: player, showTranslation: showTranslation)
                case .summary:
                    SummaryView(lecture: lecture, job: summaryJob)
                case .ask:
                    AskView(lecture: lecture, session: askSession)
                case .bookmarks:
                    BookmarksView(lecture: lecture, player: player)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            PlayerBar(player: player)
        }
        .navigationTitle(lecture.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: lecture.audioSegments) {
            await player.load(urls: LectureStore.audioURLs(for: lecture), title: lecture.title)
        }
        .task(id: lecture.id) {
            // Whatever the recording screen left behind: refined translations, then missing ones.
            await collectRefinement()
            await translateMissing(automatic: true)
        }
        .onDisappear {
            player.teardown()
            // Gap filling and refinement belong to BackgroundWork and keep running.
        }
        .translationTask(translationConfiguration) { session in
            await translationQueue.run(with: session)
        }
        .confirmationDialog("استبدال النص كاملاً؟", isPresented: $confirmRetranscribe, titleVisibility: .visible) {
            Button("فرّغ الصوت كله من جديد واحذف النص الحالي", role: .destructive) { retranscribeEverything() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("يحذف كل الجمل وترجماتها وأسماء المتحدثين ويستبدلها بتفريغ Apple على الجهاز. لإكمال الأجزاء الناقصة فقط استخدم «أكمل النص الناقص».")
        }
        .alert("إعادة تسمية المحاضرة", isPresented: $showRename) {
            TextField("العنوان", text: $draftTitle)
            Button("حفظ") {
                let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    lecture.title = trimmed
                    try? context.save()
                }
            }
            Button("إلغاء", role: .cancel) {}
        }
    }

    // MARK: - Parts

    private var infoLine: some View {
        HStack(spacing: 8) {
            Text(lecture.createdAt, format: .dateTime.day().month(.wide).year())
            Text("·")
            Text(TimeFormat.duration(lecture.duration))
            Text("·")
            Text(Languages.name(for: lecture.sourceLanguage))
            if let message = work.status[lecture.id] ?? status {
                Text("·")
                Text(message).foregroundStyle(.blue)
            } else if translationQueue.pendingCount > 0 {
                Text("·")
                Text("بانتظار الترجمة: \(translationQueue.pendingCount)").foregroundStyle(.blue)
            }
            if translationQueue.failedCount > 0 {
                Text("·")
                Text("تعذّرت ترجمة \(translationQueue.failedCount)").foregroundStyle(.orange)
            }
            if lecture.refineJobID != nil {
                Text("·")
                Label("تحسين الترجمة على الخادم", systemImage: "clock").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var incompleteBanner: some View {
        HStack {
            let seconds = lecture.untranscribedSeconds
            Label(seconds > 0 ? "\(TimeFormat.duration(seconds)) من الصوت دون نص." : "جزء من الصوت لم يُفرَّغ بعد.",
                  systemImage: "exclamationmark.bubble")
            Spacer()
            Button("أكمل النص الناقص") { fillGaps() }
                .buttonStyle(.bordered)
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: $showTranslation) {
                Label("إظهار الترجمة", systemImage: "character.bubble")
            }
        }
        ToolbarItem {
            Menu {
                ForEach(LectureExporter.Format.allCases) { format in
                    Button {
                        export(format)
                    } label: {
                        Label(format.title, systemImage: format.systemImage)
                    }
                }
            } label: {
                Label("تصدير", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItem {
            Menu {
                Picker(selection: $lecture.sourceLanguage) {
                    ForEach(Languages.lecture) { Text($0.name).tag($0.id) }
                } label: {
                    Label("لغة المحاضرة", systemImage: "globe")
                }
                .pickerStyle(.menu)
                Button {
                    Task { await translateMissing(automatic: false) }
                } label: {
                    Label("ترجمة الجمل غير المترجمة", systemImage: "translate")
                }
                Button {
                    refineTranslation()
                } label: {
                    Label("حسّن الترجمة بالسياق والمسرد (Claude)", systemImage: "wand.and.stars")
                }
                .disabled(isWorking || lecture.segments.isEmpty)
                Button {
                    fillGaps()
                } label: {
                    Label("أكمل النص الناقص من الصوت", systemImage: "text.badge.plus")
                }
                .disabled(isWorking)
                Button(role: .destructive) {
                    lecture.segments.isEmpty ? retranscribeEverything() : (confirmRetranscribe = true)
                } label: {
                    Label("استبدال النص كاملاً بتفريغ جديد", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(isWorking)
                if isWorking {
                    Button("إيقاف العملية الجارية", role: .cancel) { work.cancel(lectureID: lecture.id) }
                }
                Button {
                    draftTitle = lecture.title
                    showRename = true
                } label: {
                    Label("إعادة التسمية", systemImage: "pencil")
                }
            } label: {
                Label("المزيد", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Translation

    /// Automatic on open: only with installed languages (no prompts). Manual: may ask to download.
    private func translateMissing(automatic: Bool) async {
        let target = lecture.targetLanguage ?? AppSettings.current.targetLanguage
        guard Languages.code(target) != Languages.code(lecture.sourceLanguage) else {
            if !automatic { status = "لغة الترجمة هي نفس لغة المحاضرة." }
            return
        }
        if automatic && lecture.targetLanguage == nil { return }
        let missing = lecture.sortedSegments.filter { $0.translation == nil }
        guard !missing.isEmpty else {
            if !automatic { status = "كل الجمل مترجمة." }
            return
        }
        lecture.targetLanguage = target
        let byID = Dictionary(uniqueKeysWithValues: missing.map { ($0.uid, $0) })
        let context = context
        translationQueue.onTranslated = { id, text in
            byID[id]?.translation = text
            try? context.save()
        }
        translationQueue.removeAll()
        missing.forEach { translationQueue.enqueue(id: $0.uid, text: $0.text) }
        status = nil
        if let session = await TranslationSupport.installedSession(source: lecture.sourceLanguage, target: target, purpose: .document) {
            translationQueue.finishWhenDrained()
            await translationQueue.run(with: session)
        } else if !automatic {
            if translationConfiguration == nil {
                translationConfiguration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: lecture.sourceLanguage),
                    target: Locale.Language(identifier: target)
                )
            } else {
                translationConfiguration?.invalidate()
            }
        }
    }

    private func refineTranslation() {
        let settings = AppSettings.current
        if settings.refineEngine != "now", let server = ServerClient.current {
            Task {
                do {
                    try await TranslationRefiner.submit(lecture, server: server, engine: settings.refineEngine)
                    try? context.save()
                    status = "أُرسل تحسين الترجمة إلى الخادم؛ يكتمل خلال ساعة تقريباً."
                } catch {
                    status = error.localizedDescription
                }
            }
            return
        }
        let lecture = lecture
        let context = context
        work.start(lectureID: lecture.id, title: "تحسين ترجمة «\(lecture.title)»") { progress in
            let changed = try await TranslationRefiner.refineNow(lecture, context: context, progress: progress)
            return "حُسّنت ترجمة \(changed) جملة."
        }
    }

    private func collectRefinement() async {
        guard lecture.refineJobID != nil, let server = ServerClient.current else { return }
        if (try? await TranslationRefiner.collect(lecture, server: server, context: context)) == true,
           lecture.translationRefinedAt != nil {
            status = "وصلت الترجمة المحسّنة."
        }
    }

    // MARK: - Transcription

    private func fillGaps() {
        let lecture = lecture
        let context = context
        work.start(lectureID: lecture.id, title: "إكمال نص «\(lecture.title)»") { progress in
            let added = try await GapFiller.fill(lecture, context: context, progress: progress)
            return added == 0 ? "لا جمل جديدة في الأجزاء الناقصة." : "أُضيفت \(added) جملة من الصوت."
        }
    }

    /// 0.1 behaviour, now explicit and confirmed: replaces everything with Apple's file transcription.
    private func retranscribeEverything() {
        let lecture = lecture
        let context = context
        work.start(lectureID: lecture.id, title: "تفريغ «\(lecture.title)» من جديد") { progress in
            let urls = LectureStore.audioURLs(for: lecture)
            let segments = try await FileTranscriber.transcribe(
                urls: urls, language: lecture.sourceLanguage, vocabulary: AppSettings.current.vocabulary
            ) { message in
                Task { @MainActor in progress(0.5, message) }
            }
            try Task.checkCancellation()
            for old in lecture.segments { context.delete(old) }
            for item in segments {
                let segment = TranscriptSegment(start: item.start, end: item.end, text: item.text)
                context.insert(segment)
                segment.lecture = lecture
            }
            lecture.gaps = []
            lecture.transcriptionIncomplete = false
            try context.save()
            try? LectureArchive.write(lecture)
            return "اكتمل التفريغ: \(segments.count) جملة"
        }
    }

    private func export(_ format: LectureExporter.Format) {
        Task {
            status = "تجهيز الملف…"
            do {
                let url = try await LectureExporter.export(lecture, as: format)
                status = nil
                SharePresenter.share([url])
            } catch {
                status = "تعذّر التصدير: \(error.localizedDescription)"
            }
        }
    }
}
