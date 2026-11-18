import Foundation

/// What the model reads: the transcript as timestamped paragraphs, plus the task.
@MainActor
enum LecturePrompt {
    /// Groups phrases into ~1-minute paragraphs, each opening with its [hh:mm:ss] position.
    static func transcriptParagraphs(for lecture: Lecture) -> [String] {
        transcriptParagraphs(of: lecture.sortedSegments)
    }

    static func transcriptParagraphs(of segments: [TranscriptSegment]) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var paragraphStart: Double?
        var speaker: String?
        for segment in segments {
            let speakerChanged = segment.speaker != nil && segment.speaker != speaker
            if let start = paragraphStart, segment.start - start >= 60 || speakerChanged {
                paragraphs.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                paragraphStart = nil
            }
            if paragraphStart == nil {
                paragraphStart = segment.start
                speaker = segment.speaker
                current = TimeFormat.stamp(segment.start) + (segment.speaker.map { " (Speaker \($0))" } ?? "") + " "
            }
            current += segment.text + " "
        }
        if !current.isEmpty { paragraphs.append(current.trimmingCharacters(in: .whitespaces)) }
        return paragraphs
    }

    static func transcript(for lecture: Lecture) -> String {
        transcriptParagraphs(for: lecture).joined(separator: "\n\n")
    }

    static func preamble(for lecture: Lecture) -> String {
        let date = lecture.createdAt.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "en_US")))
        return """
        You are the study assistant in Dawwen, a lecture-recording app. The system text that follows is the \
        complete transcript of one lecture, recorded on \(date), \(TimeFormat.englishDuration(lecture.duration)) \
        long, spoken mainly in \(Languages.englishName(for: lecture.sourceLanguage)). It comes from automatic \
        speech recognition, so expect misheard words, missing punctuation and occasional wrong speaker labels. \
        Every paragraph starts with its [hh:mm:ss] position in the recording.
        """
    }

    static func summaryRequest(for lecture: Lecture, outputLanguage: String) -> String {
        let language = Languages.englishName(for: outputLanguage)
        let marks = lecture.bookmarks.sorted().map(TimeFormat.stamp).joined(separator: ", ")
        let bookmarkSection = marks.isEmpty ? "" : """

        ## Moments the student marked
        The student marked these moments as important: \(marks). For each one, explain what was being taught at that point.

        """
        return """
        Write study notes for this lecture in \(language). The reader is the student who attended and will use them to review for exams.

        Format them as Markdown, with every heading written in \(language):

        # A short, specific title for the lecture

        ## Summary
        Five to eight sentences on what the lecture set out to teach and what it concluded.

        ## Main topics
        One `###` subsection per topic, in the order it was taught. End each subsection heading with the topic's start time from the transcript, like [00:12:30]. Give each topic three to six bullet points.

        ## Key terms
        `- **term** (the term as the lecturer said it, when that differs): the definition as explained in the lecture`

        ## Examples and worked problems
        The examples, cases, formulas and calculations the lecturer went through, each with its timestamp.
        \(bookmarkSection)
        ## Assignments, deadlines and exam hints
        Only if the lecturer mentioned any; otherwise leave this section out.

        ## Review questions
        Eight to twelve questions that test understanding, each followed by a one- or two-sentence answer.

        Ground every statement in the transcript. Where a recognition error is obvious from context, write the intended word; where a key term stays unclear, keep it and mark it (?). Copy timestamps exactly as they appear in the transcript.
        """
    }

    // MARK: - While recording

    static func livePreamble(for lecture: Lecture, elapsed: Double) -> String {
        """
        You are the study assistant in Dawwen, a lecture-recording app, helping a student during a lecture \
        that is still going on. The system text that follows is the transcript so far: \
        \(TimeFormat.englishDuration(elapsed)) of a lecture spoken mainly in \
        \(Languages.englishName(for: lecture.sourceLanguage)). It comes from live speech recognition, so expect \
        misheard words, missing punctuation and occasional wrong speaker labels. Every paragraph starts with its \
        [hh:mm:ss] position; the last lines are what is being said right now.
        """
    }

    /// The live transcript, with the phrase still being recognised at the end.
    static func liveTranscript(_ segments: [TranscriptSegment], partial: String) -> String {
        var paragraphs = transcriptParagraphs(of: segments)
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { paragraphs.append("(being said now) " + partial) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The lecturer just asked the class something: find the question and give an answer to say aloud.
    static func lecturerQuestionRequest(lectureLanguage: String, outputLanguage: String) -> String {
        let spoken = Languages.englishName(for: lectureLanguage)
        let reading = Languages.englishName(for: outputLanguage)
        let translation = Languages.code(lectureLanguage) == Languages.code(outputLanguage)
            ? ""
            : "\n**Translation:** the answer in \(reading)."
        return """
        The lecturer has just asked the class a question. Find the most recent question the lecturer asked, in the last few minutes of the transcript, and answer it so the student can say the answer aloud in class.

        Reply in this format:
        **Question:** the question, in \(spoken), as the lecturer meant it.
        **Answer:** one to three short sentences in \(spoken), ready to say aloud.\(translation)
        **Why:** one sentence in \(reading), pointing to the [hh:mm:ss] moment in the lecture it comes from, or saying it is general knowledge.

        Base the answer on what was taught in this lecture first. If there is no question from the lecturer in the last few minutes, say so in one sentence in \(reading).
        """
    }

    // MARK: - Key terms sheet

    /// The vocabulary sheet a student reviews before the exam (`KeyTerms.outputSchema`).
    static func keyTermsRequest(lectureLanguage: String, readingLanguage: String, glossary: [GlossaryEntry]) -> String {
        let spoken = Languages.englishName(for: lectureLanguage)
        let reading = Languages.englishName(for: readingLanguage)
        let translationRule = Languages.code(lectureLanguage) == Languages.code(readingLanguage)
            ? "- translation: leave it empty."
            : "- translation: the usual \(reading) equivalent, as a good textbook would write it. For an abbreviation, its expansion and then the translation."
        let fixed = glossary.isEmpty ? "" : "\n\nThe student keeps these fixed translations; use them whenever one of these terms appears:\n"
            + glossary.prefix(200).map { "- \($0.term) = \($0.translation)" }.joined(separator: "\n")
        return """
        Make the vocabulary sheet for this lecture: the key terms and words the student needs to know and will review before the exam. The student reads it in \(reading).

        Include:
        - every technical term, concept, named method, law, formula or abbreviation that the lecture teaches or relies on;
        - important academic or general \(spoken) words that a student reading in \(reading) may not know and needs in order to follow the lecture.
        Leave out everyday words, filler, and things mentioned only in passing.

        For each entry:
        - term: as used in the lecture, in \(spoken), with obvious speech-recognition errors corrected; in its base form (singular, infinitive) unless the lecture uses a fixed phrase.
        - kind: "term" for a technical term or concept, "word" for a general word.
        \(translationRule)
        - meaning: one or two short sentences in \(reading) on what it means in this lecture, as the lecturer explained it.
        - example: one short sentence in \(spoken) from the lecture that uses it, lightly cleaned up (the lecturer's own example when there is one).
        - time: the [hh:mm:ss] position where it is first explained, copied exactly from the transcript.

        Order the entries by when they first come up, and never list a term twice. Scale the list with the lecture: about 15 entries for a short or light lecture, up to 60 for a long, dense one.\(fixed)
        """
    }

    // MARK: - Questions and tutoring

    /// One earlier question and answer, so follow-ups ("explain it again", a quiz answer) make sense.
    struct Exchange {
        let question: String
        let answer: String
    }

    /// `history` is oldest first. `live`: the lecture is still going on.
    static func questionRequest(_ question: String, outputLanguage: String, lectureLanguage: String, bilingual: Bool,
                                live: Bool = false, history: [Exchange] = []) -> String {
        var text = """
        Answer the student's message using the lecture transcript. Cite the [hh:mm:ss] timestamps your answer draws on. If the lecture does not cover the question, say so plainly; you may then add a general explanation, labelled as not coming from the lecture.

        \(tutorGuide(outputLanguage: outputLanguage, lectureLanguage: lectureLanguage, bilingual: bilingual, live: live))
        """
        if !history.isEmpty {
            text += "\n\nCONVERSATION SO FAR (oldest first):\n" + history.map { exchange in
                let answer = exchange.answer.count > 1_500 ? String(exchange.answer.prefix(1_500)) + "…" : exchange.answer
                return "Student: \(exchange.question)\nYou: \(answer)"
            }.joined(separator: "\n\n")
        }
        return text + "\n\nStudent's message: \(question)"
    }

    /// How the assistant teaches: when to go deep with examples and when to stay short.
    static func tutorGuide(outputLanguage: String, lectureLanguage: String, bilingual: Bool, live: Bool) -> String {
        let language = Languages.englishName(for: outputLanguage)
        let spoken = Languages.englishName(for: lectureLanguage)
        // The student picked the language in the app; their message may be in another one
        // (typing Russian or Arabic on the go is slow), so it doesn't decide.
        let keep = "whatever language the lecture or the student's message is in, unless the student explicitly asks for another language"
        let languageRule: String
        if Languages.code(outputLanguage) == Languages.code(lectureLanguage) {
            languageRule = "Always answer in \(language), \(keep)."
        } else if bilingual {
            languageRule = "Always answer in both \(language) and \(spoken), \(keep): the answer in \(language) first, then the same answer in \(spoken) after a line containing only ---. After a long explanation, the \(spoken) part may keep to the key points. Write each technical term in both languages the first time, the \(language) term followed by the \(spoken) one in parentheses."
        } else {
            languageRule = "Always answer in \(language), \(keep). Give each technical term in \(spoken), the lecture's language, in parentheses the first time it appears."
        }
        let pace = live
            ? "\n- The lecture is still going on and the student reads between moments of listening. Unless they ask for detail, keep to a few short lines they can read in seconds."
            : ""
        return """
        How to teach (you are a patient tutor, not a search engine):
        - Match the depth to the message. A quick factual question (a definition, a date, "what did they say about X") gets one to three sentences. "Explain", "why", "how", "I don't get it", or a concept that is clearly new or hard gets a real explanation: the idea in one plain sentence, then step by step, then an example (the lecturer's own example first, with its timestamp, otherwise an everyday one), then the common mistake to avoid.
        - When the student asks for detail, examples or "more", be generous. When they ask for a summary, a definition or "briefly", be brief.
        - Build on what the lecture already covered, define each new term the first time, use an analogy when an idea is abstract, and use numbered steps or a small table for a process or a comparison.
        - Keep it a conversation. After a long explanation, end with one short question that checks understanding or offers the next step (an example, a quiz question, going deeper). Skip this after short answers.
        - When the student answers a quiz question you asked, first say whether it is right, partly right or wrong, then explain what was missing, kindly and briefly, and offer another question.
        - Read "this", "it" or "again" against the conversation so far, and build on what you already explained instead of repeating it.\(pace)
        - \(languageRule)
        - Use Markdown: short paragraphs, **bold** for key terms, bullet points for lists.
        """
    }
}
