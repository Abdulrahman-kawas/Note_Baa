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
    /// What's typed in the question field, kept here so the transcript can quote sentences into it.
    var draft = ""
    /// Set when a quote is added, so the question field takes the cursor.
    var wantsInputFocus = false

    var isBusy: Bool { entries.last?.isStreaming == true }

    /// Adds a line from the transcript to the question being typed, on a line of its own.
    func quote(_ text: String) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = (typed.isEmpty ? "" : typed + "\n") + text + "\n"
        wantsInputFocus = true
    }

    /// `label` is what the history shows instead of `question` (a skill's name).
    func ask(_ question: String, label: String? = nil, about lecture: Lecture) {
        let settings = AppSettings.current
        // Same preamble and transcript as the summary request, so the cached system prefix is reused
        // (the cache is per model: summary and questions share it only when they use the same model).
        let request = ClaudeClient.Request(
            preamble: LecturePrompt.preamble(for: lecture),
            context: LecturePrompt.transcript(for: lecture),
            userMessage: LecturePrompt.questionRequest(question, outputLanguage: Self.answerLanguage(for: lecture),
                                                       lectureLanguage: lecture.sourceLanguage,
                                                       bilingual: settings.bilingualAnswers, history: Self.history(of: lecture)),
            effort: "medium",
            maxTokens: 16_000
        )
        send(label ?? question, request: request, about: lecture)
    }

    /// While recording, over the transcript so far. A nil question answers the question the lecturer
    /// just asked the class.
    func askLive(_ question: String?, label: String? = nil, about lecture: Lecture, recording: RecordingController) {
        let settings = AppSettings.current
        let language = Self.answerLanguage(for: lecture)
        let userMessage = question.map {
            LecturePrompt.questionRequest($0, outputLanguage: language, lectureLanguage: lecture.sourceLanguage,
                                          bilingual: settings.bilingualAnswers, live: true, history: Self.history(of: lecture))
        } ?? LecturePrompt.lecturerQuestionRequest(lectureLanguage: lecture.sourceLanguage, outputLanguage: language)
        let request = ClaudeClient.Request(
            preamble: LecturePrompt.livePreamble(for: lecture, elapsed: recording.elapsed),
            context: LecturePrompt.liveTranscript(recording.liveSegments, partial: recording.partialText),
            userMessage: userMessage,
            effort: "low",  // the student is waiting in class
            maxTokens: 8_000
        )
        send(label ?? question ?? "The lecturer's question at \(TimeFormat.clock(recording.elapsed))",
             request: request, about: lecture)
    }

    /// The translation language of this lecture (or the one fixed in Settings): Russian translation,
    /// Russian answers.
    private static func answerLanguage(for lecture: Lecture) -> String {
        AppSettings.current.answerLanguage(lectureTarget: lecture.targetLanguage)
    }

    /// The last few answered questions, so a follow-up or a quiz answer has its context.
    private static func history(of lecture: Lecture) -> [LecturePrompt.Exchange] {
        lecture.questions
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(4)
            .map { LecturePrompt.Exchange(question: $0.question, answer: $0.answer) }
    }

    private func send(_ question: String, request: ClaudeClient.Request, about lecture: Lecture) {
        var entry = Entry(question: question)
        let model = AppSettings.current.askModel.resolved()
        // Haiku by default: a question re-reads the cached transcript for a fraction of a cent.
        guard let client = model.client() else {
            entry.error = model.missingKeyError.localizedDescription
            entry.isStreaming = false
            entries.append(entry)
            return
        }
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
            save(id, about: lecture)
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// Keeps a finished answer with the lecture so it is still there next time. Failed questions stay
    /// in the session so the error remains visible.
    private func save(_ id: UUID, about lecture: Lecture) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        guard entry.error == nil, !entry.answer.isEmpty else { return }
        let saved = QAEntry(question: entry.question, answer: entry.answer)
        lecture.modelContext?.insert(saved)
        saved.lecture = lecture
        entries.remove(at: index)
    }
}

struct AskView: View {
    let lecture: Lecture
    @Bindable var session: AskSession
    /// While recording: questions go over the transcript so far, and one button answers the
    /// question the lecturer just asked.
    var recording: RecordingController?

    @FocusState private var inputFocused: Bool
    private var examples: [String] {
        recording == nil ? [
            "What are the three most important ideas in this lecture?",
            "Explain the hardest concept in it with a simple example.",
            "Did the lecturer mention anything about the exam or assignments?"
        ] : [
            "What did I miss in the last five minutes?",
            "Explain what the lecturer is talking about right now, simply.",
            "Summarize the lecture so far in five points."
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(lecture.questions.sorted { $0.createdAt < $1.createdAt }) { saved in
                            SavedQuestionView(entry: saved)
                        }
                        if session.entries.isEmpty && lecture.questions.isEmpty {
                            Text("Ask about anything said in the lecture; answers cite timestamps.")
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
                                    .textSelection(.enabled)
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
                // While recording the panel is reopened often; it opens on the latest answer.
                .defaultScrollAnchor(recording == nil ? nil : .bottom, for: .initialOffset)
                .onChange(of: session.entries.count) {
                    if let last = session.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // A chip rather than a full-width button, so the panel fits beside the live transcript.
                    if let recording {
                        Button {
                            session.askLive(nil, about: lecture, recording: recording)
                        } label: {
                            Label("Answer the lecturer's question", systemImage: "hand.raised.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    ForEach(AskSkill.all) { skill in
                        Button {
                            send(skill.instruction, label: skill.title)
                        } label: {
                            Label(skill.title, systemImage: skill.icon)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal)
            }
            .padding(.top, 10)
            .disabled(session.isBusy)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about the lecture… / اسأل عن المحاضرة…", text: $session.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { send(session.draft) }
                Button {
                    send(session.draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .accessibilityLabel("Send")
                }
                .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isBusy)
            }
            .padding()
        }
        .task(id: session.wantsInputFocus) {
            guard session.wantsInputFocus else { return }
            session.wantsInputFocus = false
            inputFocused = true
        }
    }

    /// `label`: a skill, shown by its name and leaving whatever is typed in the field.
    private func send(_ text: String, label: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isBusy else { return }
        if let recording {
            session.askLive(trimmed, label: label, about: lecture, recording: recording)
        } else {
            session.ask(trimmed, label: label, about: lecture)
        }
        if label == nil { session.draft = "" }
    }
}

/// Ready-made requests that steer how the tutor answers. They work on the conversation so far, so
/// "Explain simply" after an answer re-explains that answer.
struct AskSkill: Identifiable {
    let title: String
    let icon: String
    let instruction: String

    var id: String { title }

    static let all: [AskSkill] = [
        AskSkill(
            title: "Explain simply · اشرح ببساطة", icon: "lightbulb",
            instruction: "Explain the last thing we discussed (or, if we haven't discussed anything yet, the main idea of the lecture so far) more simply, step by step, with an everyday analogy."
        ),
        AskSkill(
            title: "Example · مثال", icon: "list.number",
            instruction: "Give me a worked example of the last concept we discussed, step by step: the lecturer's example first if there is one, then one of your own."
        ),
        AskSkill(
            title: "Quiz me · اختبرني", icon: "questionmark.bubble",
            instruction: "Quiz me: ask me one question that tests whether I understood the last thing we discussed, or the lecture so far, focusing on what is most likely to come up in an exam. Ask only the question and wait for my answer; don't give the answer yet."
        ),
        AskSkill(
            title: "Go deeper · تعمّق", icon: "arrow.down.circle",
            instruction: "Go deeper into the last topic we discussed: the details, why it works, edge cases, and how it connects to the rest of the lecture."
        ),
        AskSkill(
            title: "Short version · باختصار", icon: "text.alignleft",
            instruction: "Give me the short version of your last answer, or of the lecture so far if there is none: three bullet points at most."
        ),
        AskSkill(
            title: "Key terms · المصطلحات", icon: "character.book.closed",
            instruction: "List the key terms from the lecture so far, each with a one-line definition as the lecturer explained it and its timestamp."
        )
    ]
}

/// A question answered earlier, shown from the lecture's saved history.
private struct SavedQuestionView: View {
    let entry: QAEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.question)
                .bold()
                .textSelection(.enabled)
                .padding(10)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .textDirection(rightToLeft: entry.question.isMostlyRTL)
            MarkdownView(text: entry.answer)
            Button {
                UIPasteboard.general.string = plainAnswer
            } label: {
                Label("Copy answer", systemImage: "doc.on.doc")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    /// The answer without the inline Markdown marks, for pasting into notes.
    private var plainAnswer: String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: entry.answer, options: options)).map { String($0.characters) } ?? entry.answer
    }
}
