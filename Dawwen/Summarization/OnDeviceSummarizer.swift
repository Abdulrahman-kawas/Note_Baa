import Foundation
import FoundationModels

/// Free, offline fallback summary with Apple's on-device model.
///
/// The on-device context window (`contextSize`, 4,096 tokens on iPadOS 26) is far smaller than a
/// 3.5-hour lecture, so the transcript is summarized in parts, then the parts are merged.
/// Apple Intelligence does not support Arabic, so this path serves the languages it does support.
enum OnDeviceSummarizer {
    static func unavailableReason(lectureLanguage: String) -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This iPad doesn't support Apple Intelligence (it needs an M1 chip or newer)."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings."
            case .modelNotReady: return "The Apple Intelligence model hasn't finished downloading yet."
            @unknown default: return "Apple Intelligence isn't available."
            }
        }
        guard model.supportsLocale(Locale(identifier: lectureLanguage)) else {
            return "Apple Intelligence doesn't support this lecture's language; use Claude."
        }
        return nil
    }

    static func summarize(
        paragraphs: [String],
        language: String,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let model = SystemLanguageModel.default
        // Leave room for instructions and the reply; ~3 characters per token is conservative for English.
        let chunkCharacters = max(2_000, (model.contextSize - 1_400) * 3)
        let languageName = Languages.englishName(for: language)
        let localeLine = Locale(identifier: language).language.languageCode?.identifier == "en"
            ? ""
            : "The person's locale is \(language). "

        let partInstructions = localeLine + """
        You summarize one part of a lecture transcript. Write 4 to 8 concise bullet points in \(languageName). \
        Keep the [hh:mm:ss] timestamps of the main points. Use only what the text says.
        """
        let mergeInstructions = localeLine + """
        You merge partial notes from one lecture into fewer, non-overlapping bullet points in \(languageName), \
        keeping the [hh:mm:ss] timestamps.
        """
        let finalInstructions = localeLine + """
        You write study notes in \(languageName) from notes of one lecture. Use Markdown: a `#` title, \
        a `## Summary` of 4 to 6 sentences, `## Main topics` with bullet points and timestamps, \
        `## Key terms`, and `## Review questions` with 5 short questions and answers.
        """

        let chunks = group(paragraphs, maxCharacters: chunkCharacters)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            await progress("Apple Intelligence: part \(index + 1) of \(chunks.count)")
            notes.append(try await respond(instructions: partInstructions, text: chunk, maxTokens: 400))
        }

        var level = notes
        while level.count > 1, level.joined(separator: "\n").count > chunkCharacters {
            await progress("Apple Intelligence: merging notes…")
            var merged: [String] = []
            for group in group(level, maxCharacters: chunkCharacters) {
                merged.append(try await respond(instructions: mergeInstructions, text: group, maxTokens: 500))
            }
            level = merged
        }

        await progress("Apple Intelligence: writing the final summary…")
        return try await respond(instructions: finalInstructions, text: level.joined(separator: "\n\n"), maxTokens: 900)
    }

    /// One fresh session per call; halves the text and retries if it still overflows the window.
    private static func respond(instructions: String, text: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: text,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, text.count > 800 else { throw error }
            let middle = text.index(text.startIndex, offsetBy: text.count / 2)
            let first = try await respond(instructions: instructions, text: String(text[..<middle]), maxTokens: maxTokens)
            let second = try await respond(instructions: instructions, text: String(text[middle...]), maxTokens: maxTokens)
            return first + "\n" + second
        }
    }

    private static func group(_ pieces: [String], maxCharacters: Int) -> [String] {
        var groups: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty, current.count + piece.count + 2 > maxCharacters {
                groups.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + piece
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
