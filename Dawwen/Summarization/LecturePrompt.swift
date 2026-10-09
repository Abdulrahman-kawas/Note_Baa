import Foundation

/// What the model reads: the transcript as timestamped paragraphs, plus the task.
@MainActor
enum LecturePrompt {
    /// Groups phrases into ~1-minute paragraphs, each opening with its [hh:mm:ss] position.
    static func transcriptParagraphs(for lecture: Lecture) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var paragraphStart: Double?
        var speaker: String?
        for segment in lecture.sortedSegments {
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

    static func questionRequest(_ question: String, outputLanguage: String) -> String {
        let language = Languages.englishName(for: outputLanguage)
        return """
        Answer the student's question in \(language), using the lecture transcript. Cite the [hh:mm:ss] timestamps your answer draws on. If the lecture does not cover the question, say so plainly; you may then add a short general explanation, labelled as not coming from the lecture.

        Question: \(question)
        """
    }
}
