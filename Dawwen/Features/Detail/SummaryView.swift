import Observation
import SwiftData
import SwiftUI

/// Generates the study notes. Lives in the detail view, so switching tabs doesn't stop it.
///
/// Three routes, cheapest first:
///  - on device (free): Apple Intelligence summarizes the English transcript in parts, then Apple
///    Translation turns the notes into Arabic; the English original is kept.
///  - Claude now: streams; a background assertion lets it finish if the student leaves the app.
///  - Claude later (gateway): one Message Batch at half price; collected when the lecture is opened.
@MainActor
@Observable
final class SummaryJob {
    private(set) var isWorking = false
    private(set) var draft = ""
    private(set) var progress: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func summarizeWithClaude(_ lecture: Lecture, context: ModelContext) {
        guard !isWorking else { return }
        let settings = AppSettings.current
        guard let client = ClaudeClient.current(model: settings.claudeModel) else {
            errorMessage = ClaudeClient.ClaudeError.missingKey.localizedDescription
            return
        }
        guard !lecture.segments.isEmpty else {
            errorMessage = "لا يوجد نص لتلخيصه بعد."
            return
        }
        let request = Self.summaryRequest(for: lecture, outputLanguage: settings.summaryLanguage)
        let modelName = settings.claudeModel.title
        run(name: "dawwen.summary") {
            self.progress = "\(modelName) يقرأ المحاضرة كاملة…"
            var text = ""
            var lastRedraw = Date.distantPast
            for try await piece in client.stream(request) {
                text += piece
                // Redraw a few times a second, not once per token.
                if Date().timeIntervalSince(lastRedraw) > 0.2 {
                    self.draft = text
                    self.progress = "\(modelName) يكتب…"
                    lastRedraw = Date()
                }
            }
            self.draft = text
            // A cancelled stream ends quietly; never save a partial summary.
            try Task.checkCancellation()
            lecture.summary = text
            lecture.summaryOriginal = nil
            lecture.summaryModel = modelName
            lecture.summaryDate = .now
            try? context.save()
            try? LectureArchive.write(lecture)
        }
    }

    /// Free and offline for English lectures: summary in English, then translated on device.
    func summarizeOnDevice(_ lecture: Lecture, context: ModelContext) {
        guard !isWorking else { return }
        if let reason = OnDeviceSummarizer.unavailableReason(lectureLanguage: lecture.sourceLanguage) {
            errorMessage = reason
            return
        }
        let paragraphs = LecturePrompt.transcriptParagraphs(for: lecture)
        guard !paragraphs.isEmpty else {
            errorMessage = "لا يوجد نص لتلخيصه بعد."
            return
        }
        let language = lecture.sourceLanguage
        let outputLanguage = AppSettings.current.summaryLanguage
        run(name: "dawwen.summary.device") {
            // The on-device model writes the lecture's language (Apple Intelligence has no Arabic).
            let original = try await OnDeviceSummarizer.summarize(paragraphs: paragraphs, language: language) { message in
                self.progress = message
            }
            try Task.checkCancellation()
            var final = original
            if Languages.code(outputLanguage) != Languages.code(language) {
                self.progress = "ترجمة الملخص إلى \(Languages.name(for: outputLanguage))…"
                if let session = await TranslationSupport.installedSession(source: language, target: outputLanguage, purpose: .document) {
                    final = try await TranslationSupport.translateMarkdown(original, with: session)
                } else {
                    self.errorMessage = "لغة الترجمة غير منزّلة؛ حُفظ الملخص بلغة المحاضرة. نزّلها من الإعدادات."
                }
            }
            lecture.summary = final
            lecture.summaryOriginal = final == original ? nil : original
            lecture.summaryModel = "Apple Intelligence (على الجهاز)"
            lecture.summaryDate = .now
            try? context.save()
            try? LectureArchive.write(lecture)
        }
    }

    /// Message Batches through the gateway: half price, ready within about an hour.
    func summarizeLater(_ lecture: Lecture, context: ModelContext) {
        guard !isWorking, let server = ServerClient.current else { return }
        let settings = AppSettings.current
        let request = Self.summaryRequest(for: lecture, outputLanguage: settings.summaryLanguage)
        let call = ServerClient.ClaudeCall(
            model: settings.claudeModel.rawValue, preamble: request.preamble, context: request.context,
            userMessage: request.userMessage, effort: request.effort, maxTokens: 32_000, outputSchema: nil
        )
        run(name: "dawwen.summary.batch") {
            self.progress = "إرسال الطلب إلى الخادم…"
            let job = try await server.createJob(ServerClient.JobRequest(
                type: "summary", lectureID: lecture.id, engine: "claude-batch", claude: call
            ))
            lecture.summaryJobID = job.id
            try? context.save()
            self.errorMessage = "أُرسل الطلب بنصف السعر. يصل الملخص خلال ساعة تقريباً؛ افتح المحاضرة لاحقاً."
        }
    }

    /// Called when the lecture opens.
    func collectPending(_ lecture: Lecture, context: ModelContext) async {
        guard let id = lecture.summaryJobID, let server = ServerClient.current else { return }
        do {
            let job = try await server.job(id)
            switch job.status {
            case "done":
                let data = try await server.result(of: job)
                let result = try JSONDecoder().decode(ServerClient.JobResult.self, from: data)
                if let text = result.results?["summary"]?.text, !text.isEmpty {
                    lecture.summary = text
                    lecture.summaryOriginal = nil
                    lecture.summaryModel = "\(AppSettings.current.claudeModel.title) (Batch)"
                    lecture.summaryDate = .now
                }
                lecture.summaryJobID = nil
                try? context.save()
                try? LectureArchive.write(lecture)
            case "failed":
                lecture.summaryJobID = nil
                try? context.save()
                errorMessage = "تعذّر الملخص المؤجل: \(job.error ?? "")"
            default:
                break
            }
        } catch {
            // Offline: try again next time.
        }
    }

    func cancel() {
        task?.cancel()
    }

    private static func summaryRequest(for lecture: Lecture, outputLanguage: String) -> ClaudeClient.Request {
        ClaudeClient.Request(
            preamble: LecturePrompt.preamble(for: lecture),
            context: LecturePrompt.transcript(for: lecture),
            userMessage: LecturePrompt.summaryRequest(for: lecture, outputLanguage: outputLanguage)
        )
    }

    private func run(name: String, _ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        draft = ""
        errorMessage = nil
        task = Task {
            let assertion = BackgroundAssertion(name: name)
            do {
                try await work()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            assertion.end()
            isWorking = false
            progress = nil
        }
    }
}

struct SummaryView: View {
    @Bindable var lecture: Lecture
    let job: SummaryJob

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.claudeModel) private var modelRaw = ClaudeModelOption.sonnet.rawValue
    @State private var showOriginal = false

    private var model: ClaudeModelOption { ClaudeModelOption(rawValue: modelRaw) ?? .sonnet }
    private var hasServer: Bool { ServerClient.current != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if job.isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(job.progress ?? "")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("إيقاف", role: .cancel) { job.cancel() }
                    }
                    if !job.draft.isEmpty {
                        MarkdownView(text: job.draft)
                    }
                } else if let summary = lecture.summary {
                    if lecture.summaryOriginal != nil {
                        Picker("اللغة", selection: $showOriginal) {
                            Text("المترجَم").tag(false)
                            Text("الأصل").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                    let shown = showOriginal ? (lecture.summaryOriginal ?? summary) : summary
                    MarkdownView(text: shown)
                    Divider()
                    HStack {
                        if let name = lecture.summaryModel, let date = lecture.summaryDate {
                            Text("\(name) · \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = shown
                        } label: {
                            Label("نسخ", systemImage: "doc.on.doc")
                        }
                        actionsMenu(title: "إعادة التلخيص")
                    }
                } else if lecture.summaryJobID != nil {
                    Label("ملخص مؤجل (Batch) قيد التحضير على الخادم.", systemImage: "clock")
                        .foregroundStyle(.secondary)
                } else {
                    emptyState
                }
                if let error = job.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            .padding()
        }
        .task(id: lecture.id) {
            await job.collectPending(lecture, context: context)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("ملخص للدراسة", systemImage: "sparkles")
                .font(.title3.bold())
            Text("محاور المحاضرة بطوابعها الزمنية، والمصطلحات، والأمثلة، وما علّمته من نقاط، ومواعيد الواجبات، وأسئلة مراجعة.")
                .foregroundStyle(.secondary)
            Button {
                job.summarizeOnDevice(lecture, context: context)
            } label: {
                Label("لخّص على الجهاز مجاناً (Apple Intelligence + الترجمة)", systemImage: "ipad")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("دون إنترنت ودون تكلفة للمحاضرات الإنجليزية. ملخص أقصر من Claude.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                job.summarizeWithClaude(lecture, context: context)
            } label: {
                Label("لخّص بـ \(model.title)", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Text("ملاحظات دراسة مفصّلة بالعربية مباشرة. يرسل النص (دون الصوت). السعر: \(model.priceNote).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasServer {
                Button {
                    job.summarizeLater(lecture, context: context)
                } label: {
                    Label("لخّص لاحقاً بنصف السعر (Batch عبر الخادم)", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func actionsMenu(title: String) -> some View {
        Menu {
            Button("على الجهاز (مجاني)") { job.summarizeOnDevice(lecture, context: context) }
            Button("بـ \(model.title)") { job.summarizeWithClaude(lecture, context: context) }
            if hasServer {
                Button("بـ \(model.title) لاحقاً (Batch)") { job.summarizeLater(lecture, context: context) }
            }
        } label: {
            Label(title, systemImage: "arrow.clockwise")
        }
    }
}
