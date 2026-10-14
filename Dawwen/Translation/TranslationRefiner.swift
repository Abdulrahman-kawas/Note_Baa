import Foundation
import SwiftData

/// After the lecture, re-translates the transcript with a language model that sees the neighbouring
/// sentences and the course glossary, so terms stay consistent and recognition slips get fixed.
/// The result goes to `refinedTranslation`, beside Apple's live translation, never over it.
///
/// Two ways to run it:
///  - now, from the iPad (Claude, 4 requests in parallel; a 4-hour lecture takes a few minutes);
///  - later, through the gateway as one Message Batch (half price, done within the hour, the iPad
///    may sleep), or on the home worker with a local model.
@MainActor
enum TranslationRefiner {
    static let chunkSize = 50
    static let contextLines = 4

    struct Chunk: Sendable {
        let customID: String
        let userMessage: String
    }

    static let outputSchema = #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"translation":{"type":"string"}},"required":["id","translation"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}"#

    static func instructions(source: String, target: String) -> String {
        let from = Languages.englishName(for: source)
        let to = Languages.englishName(for: target)
        let register = Languages.code(target) == "ar"
            ? "Write clear Modern Standard Arabic in the register of a good university textbook."
            : "Write clear, natural \(to) in an academic register."
        return """
        You translate a university lecture transcript from \(from) into \(to) for a student who attended it. \(register)

        Rules:
        - Translate every line under TRANSLATE. Return exactly one item per line, with the same id. Never merge, split or skip lines.
        - Lines under CONTEXT are there to help you understand; do not translate them.
        - The text comes from speech recognition. Where a word was obviously misheard, translate what the lecturer meant. Add nothing that was not said.
        - Use the glossary translations exactly. For any other technical term, use the standard \(to) term and add the original term in parentheses the first time it appears in this part, for example: الانحدار الخطي (linear regression).
        - Keep numbers, formulas, code, units and names of people as they are.
        """
    }

    /// "term = translation" lines from Settings, as a stable block (prompt-cached with the instructions).
    static func glossaryText() -> String {
        let entries = AppSettings.current.glossary
        guard !entries.isEmpty else { return "" }
        return "GLOSSARY (use these translations):\n" + entries.map { "\($0.term) = \($0.translation)" }.joined(separator: "\n")
    }

    static func chunks(for lecture: Lecture) -> [Chunk] {
        let segments = lecture.sortedSegments
        return stride(from: 0, to: segments.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, segments.count)
            var text = ""
            let before = segments[max(0, start - contextLines)..<start]
            if !before.isEmpty {
                text += "CONTEXT BEFORE:\n" + before.map(\.text).joined(separator: "\n") + "\n\n"
            }
            text += "TRANSLATE:\n" + segments[start..<end].map { "[\($0.uid.uuidString)] \($0.text)" }.joined(separator: "\n")
            let after = segments[end..<min(segments.count, end + contextLines)]
            if !after.isEmpty {
                text += "\n\nCONTEXT AFTER:\n" + after.map(\.text).joined(separator: "\n")
            }
            return Chunk(customID: "chunk-\(start / chunkSize)", userMessage: text)
        }
    }

    /// Applies `{"items":[{"id","translation"}]}`. Returns the number of phrases updated.
    @discardableResult
    static func apply(_ json: String, to lecture: Lecture) -> Int {
        struct Reply: Decodable {
            struct Item: Decodable { let id: String; let translation: String }
            let items: [Item]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else { return 0 }
        let byID = Dictionary(uniqueKeysWithValues: lecture.segments.map { ($0.uid.uuidString, $0) })
        var changed = 0
        for item in reply.items {
            let key = item.id.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let translation = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let segment = byID[key], !translation.isEmpty else { continue }
            segment.refinedTranslation = translation
            changed += 1
        }
        return changed
    }

    // MARK: - Now, from the iPad

    static func refineNow(_ lecture: Lecture, context: ModelContext, progress: @escaping BackgroundWork.ProgressHandler) async throws -> Int {
        let target = lecture.targetLanguage ?? AppSettings.current.targetLanguage
        guard let client = ClaudeClient.current(model: AppSettings.current.refineModel) else {
            throw ClaudeClient.ClaudeError.missingKey
        }
        let preamble = instructions(source: lecture.sourceLanguage, target: target)
        let glossary = glossaryText()
        let requests = chunks(for: lecture).map {
            ClaudeClient.Request(preamble: preamble, context: glossary, userMessage: $0.userMessage,
                                 effort: "low", maxTokens: 16_000, outputSchema: outputSchema)
        }
        guard !requests.isEmpty else { return 0 }
        var changed = 0
        var done = 0
        try await withThrowingTaskGroup(of: String.self) { group in
            var next = 0
            while next < min(4, requests.count) {
                let request = requests[next]
                next += 1
                group.addTask { try await client.complete(request) }
            }
            while let json = try await group.next() {
                changed += apply(json, to: lecture)
                done += 1
                progress(Double(done) / Double(requests.count), "Refining translation: \(done) of \(requests.count)")
                try context.save()
                if next < requests.count {
                    let request = requests[next]
                    next += 1
                    group.addTask { try await client.complete(request) }
                }
            }
        }
        lecture.targetLanguage = target
        lecture.translationRefinedAt = .now
        try context.save()
        try? LectureArchive.write(lecture)
        return changed
    }

    // MARK: - Later, through the gateway

    static func submit(_ lecture: Lecture, server: ServerClient, engine: String) async throws {
        let target = lecture.targetLanguage ?? AppSettings.current.targetLanguage
        let payload = ServerClient.RefinePayload(
            model: AppSettings.current.refineModel.rawValue,
            preamble: instructions(source: lecture.sourceLanguage, target: target),
            context: glossaryText(),
            effort: "low",
            maxTokens: 16_000,
            outputSchema: outputSchema,
            requests: chunks(for: lecture).map { ServerClient.RefineRequest(customID: $0.customID, userMessage: $0.userMessage) }
        )
        let job = try await server.createJob(ServerClient.JobRequest(
            type: "refine_translation", lectureID: lecture.id, engine: engine, refine: payload
        ))
        lecture.targetLanguage = target
        lecture.refineJobID = job.id
    }

    /// Returns true when the job finished (and was applied or failed).
    static func collect(_ lecture: Lecture, server: ServerClient, context: ModelContext) async throws -> Bool {
        guard let id = lecture.refineJobID else { return true }
        let job = try await server.job(id)
        switch job.status {
        case "done":
            let result = try JSONDecoder().decode(ServerClient.JobResult.self, from: try await server.result(of: job))
            for item in (result.results ?? [:]).values {
                if let text = item.text { apply(text, to: lecture) }
            }
            lecture.refineJobID = nil
            lecture.translationRefinedAt = .now
            try context.save()
            try? LectureArchive.write(lecture)
            return true
        case "failed":
            lecture.refineJobID = nil
            try context.save()
            return true
        default:
            return false
        }
    }
}
