import Observation
import SwiftUI

/// Questions about one lecture. Each question is its own request over the same cached transcript,
/// so after the first one the transcript is read from Anthropic's prompt cache.
@MainActor
@Observable
final class AskSession {
    struct Entry: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var isStreaming = true
        var error: String?
    }

    private(set) var entries: [Entry] = []

    var isBusy: Bool { entries.last?.isStreaming == true }

    func ask(_ question: String, about lecture: Lecture) {
        var entry = Entry(question: question)
        let settings = AppSettings.current
        // Haiku by default: a question re-reads the cached transcript for a fraction of a cent.
        guard let client = ClaudeClient.current(model: settings.askModel) else {
            entry.error = ClaudeClient.ClaudeError.missingKey.localizedDescription
            entry.isStreaming = false
            entries.append(entry)
            return
        }
        // Same preamble and transcript as the summary request, so the cached system prefix is reused
        // (the cache is per model: summary and questions share it only when they use the same model).
        let request = ClaudeClient.Request(
            preamble: LecturePrompt.preamble(for: lecture),
            context: LecturePrompt.transcript(for: lecture),
            userMessage: LecturePrompt.questionRequest(question, outputLanguage: settings.summaryLanguage),
            effort: "medium",
            maxTokens: 16_000
        )
        entries.append(entry)
        let id = entry.id
        Task {
            do {
                for try await piece in client.stream(request) {
                    update(id) { $0.answer += piece }
                }
            } catch {
                update(id) { $0.error = error.localizedDescription }
            }
            update(id) { $0.isStreaming = false }
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}

struct AskView: View {
    let lecture: Lecture
    let session: AskSession

    @State private var question = ""
    private let examples = [
        "ما أهم ثلاث أفكار في هذه المحاضرة؟",
        "اشرح أصعب مفهوم ورد فيها بمثال بسيط.",
        "هل ذكر المحاضر شيئاً عن الامتحان أو الواجبات؟"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if session.entries.isEmpty {
                            Text("اسأل عن أي شيء قيل في المحاضرة؛ الإجابة تذكر الطوابع الزمنية.")
                                .foregroundStyle(.secondary)
                            ForEach(examples, id: \.self) { example in
                                Button(example) { send(example) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        ForEach(session.entries) { entry in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(entry.question)
                                    .bold()
                                    .padding(10)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                    .textDirection(rightToLeft: entry.question.isMostlyRTL)
                                if let error = entry.error {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.red)
                                        .font(.footnote)
                                } else if entry.answer.isEmpty {
                                    ProgressView()
                                } else {
                                    MarkdownView(text: entry.answer)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.entries.count) {
                    if let last = session.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("اسأل عن المحاضرة…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(question) }
                Button {
                    send(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .accessibilityLabel("إرسال")
                }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || session.isBusy)
            }
            .padding()
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isBusy else { return }
        session.ask(trimmed, about: lecture)
        question = ""
    }
}
