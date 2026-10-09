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
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var tab: DetailTab = .transcript
    @State private var showTranslation = true
    @State private var transcribeTask: Task<Void, Never>?
    @State private var status: String?
    @State private var confirmRetranscribe = false
    @State private var showRename = false
    @State private var draftTitle = ""

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

            if lecture.transcriptionIncomplete && transcribeTask == nil {
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
            await player.load(urls: LectureStore.audioURLs(for: lecture))
        }
        .onDisappear {
            player.teardown()
            transcribeTask?.cancel()
        }
        .translationTask(translationConfiguration) { session in
            await translationQueue.run(with: session)
        }
        .confirmationDialog("إعادة التفريغ من الصوت؟", isPresented: $confirmRetranscribe, titleVisibility: .visible) {
            Button("استبدال النص الحالي", role: .destructive) { transcribeFromAudio() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("يُفرَّغ التسجيل كاملاً على الجهاز ويحل محل النص والترجمة الحاليين.")
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
            if let status {
                Text("·")
                Text(status).foregroundStyle(.blue)
            } else if translationQueue.pendingCount > 0 {
                Text("·")
                Text("بانتظار الترجمة: \(translationQueue.pendingCount)").foregroundStyle(.blue)
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
            Label("جزء من الصوت لم يُفرَّغ بعد.", systemImage: "exclamationmark.bubble")
            Spacer()
            Button("فرّغ من الصوت") {
                lecture.segments.isEmpty ? transcribeFromAudio() : (confirmRetranscribe = true)
            }
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
                    translateMissing()
                } label: {
                    Label("ترجمة الجمل غير المترجمة", systemImage: "translate")
                }
                Button {
                    lecture.segments.isEmpty ? transcribeFromAudio() : (confirmRetranscribe = true)
                } label: {
                    Label("إعادة التفريغ من الصوت", systemImage: "waveform.badge.magnifyingglass")
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

    // MARK: - Actions

    private func translateMissing() {
        let target = lecture.targetLanguage ?? AppSettings.current.targetLanguage
        guard Languages.code(target) != Languages.code(lecture.sourceLanguage) else {
            status = "لغة الترجمة هي نفس لغة المحاضرة."
            return
        }
        lecture.targetLanguage = target
        let missing = lecture.sortedSegments.filter { $0.translation == nil }
        guard !missing.isEmpty else {
            status = "كل الجمل مترجمة."
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: missing.map { ($0.uid, $0) })
        let context = context
        translationQueue.onTranslated = { id, text in
            byID[id]?.translation = text
            try? context.save()
        }
        translationQueue.removeAll()
        missing.forEach { translationQueue.enqueue(id: $0.uid, text: $0.text) }
        status = nil
        if translationConfiguration == nil {
            translationConfiguration = TranslationSession.Configuration(
                source: Locale.Language(identifier: lecture.sourceLanguage),
                target: Locale.Language(identifier: target)
            )
        } else {
            translationConfiguration?.invalidate()
        }
    }

    private func transcribeFromAudio() {
        transcribeTask?.cancel()
        let urls = LectureStore.audioURLs(for: lecture)
        let language = lecture.sourceLanguage
        let vocabulary = AppSettings.current.vocabulary
        status = "تجهيز التفريغ…"
        transcribeTask = Task {
            do {
                let segments = try await FileTranscriber.transcribe(urls: urls, language: language, vocabulary: vocabulary) { message in
                    Task { @MainActor in status = message }
                }
                try Task.checkCancellation()
                for old in lecture.segments { context.delete(old) }
                for item in segments {
                    let segment = TranscriptSegment(start: item.start, end: item.end, text: item.text)
                    context.insert(segment)
                    segment.lecture = lecture
                }
                lecture.transcriptionIncomplete = false
                try? context.save()
                status = "اكتمل التفريغ: \(segments.count) جملة"
            } catch is CancellationError {
                status = nil
            } catch {
                status = error.localizedDescription
            }
            transcribeTask = nil
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
