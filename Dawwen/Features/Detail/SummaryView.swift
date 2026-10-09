import Observation
import SwiftData
import SwiftUI

/// Generates the study notes. Lives in the detail view, so switching tabs doesn't stop it.
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
        guard let key = KeychainStore.read(.anthropic) else {
            errorMessage = ClaudeClient.ClaudeError.missingKey.localizedDescription
            return
        }
        guard !lecture.segments.isEmpty else {
            errorMessage = "لا يوجد نص لتلخيصه بعد."
            return
        }
        let settings = AppSettings.current
        let client = ClaudeClient(apiKey: key, model: settings.claudeModel)
        let request = ClaudeClient.Request(
            preamble: LecturePrompt.preamble(for: lecture),
            context: LecturePrompt.transcript(for: lecture),
            userMessage: LecturePrompt.summaryRequest(for: lecture, outputLanguage: settings.summaryLanguage)
        )
        let modelName = settings.claudeModel.title
        run {
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
            lecture.summaryModel = modelName
            lecture.summaryDate = .now
            try? context.save()
        }
    }

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
        run {
            let text = try await OnDeviceSummarizer.summarize(paragraphs: paragraphs, language: language) { message in
                self.progress = message
            }
            try Task.checkCancellation()
            lecture.summary = text
            lecture.summaryModel = "Apple Intelligence (على الجهاز)"
            lecture.summaryDate = .now
            try? context.save()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        draft = ""
        errorMessage = nil
        task = Task {
            do {
                try await work()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isWorking = false
            progress = nil
        }
    }
}

struct SummaryView: View {
    @Bindable var lecture: Lecture
    let job: SummaryJob

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.claudeModel) private var modelRaw = ClaudeModelOption.opus.rawValue

    private var model: ClaudeModelOption { ClaudeModelOption(rawValue: modelRaw) ?? .opus }

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
                    MarkdownView(text: summary)
                    Divider()
                    HStack {
                        if let name = lecture.summaryModel, let date = lecture.summaryDate {
                            Text("\(name) · \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = summary
                        } label: {
                            Label("نسخ", systemImage: "doc.on.doc")
                        }
                        actionsMenu(title: "إعادة التلخيص")
                    }
                } else {
                    emptyState
                }
                if let error = job.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .padding()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("ملخص للدراسة", systemImage: "sparkles")
                .font(.title3.bold())
            Text("محاور المحاضرة بطوابعها الزمنية، والمصطلحات، والأمثلة، وما علّمته من نقاط، ومواعيد الواجبات، وأسئلة مراجعة.")
                .foregroundStyle(.secondary)
            Button {
                job.summarizeWithClaude(lecture, context: context)
            } label: {
                Label("لخّص بـ \(model.title)", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("يرسل نص المحاضرة (دون الصوت) إلى Anthropic. السعر: \(model.priceNote).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                job.summarizeOnDevice(lecture, context: context)
            } label: {
                Label("لخّص على الجهاز (Apple Intelligence)", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("مجاني ودون إنترنت، للغات التي يدعمها Apple Intelligence فقط (ليست العربية).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func actionsMenu(title: String) -> some View {
        Menu {
            Button("بـ \(model.title)") { job.summarizeWithClaude(lecture, context: context) }
            Button("على الجهاز (Apple Intelligence)") { job.summarizeOnDevice(lecture, context: context) }
        } label: {
            Label(title, systemImage: "arrow.clockwise")
        }
    }
}
