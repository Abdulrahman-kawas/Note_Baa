import Foundation
import Translation

/// Apple Translation without a view. `TranslationSession(installedSource:target:)` exists since
/// iPadOS 26.0; the variant that picks a strategy arrived in 26.4. Neither can ask to download a
/// language: downloads happen once, in Settings, through `.translationTask` + `prepareTranslation()`.
@MainActor
enum TranslationSupport {
    enum Purpose {
        /// During a lecture: lowest latency.
        case live
        /// After it (missing phrases, summaries): best quality the device offers.
        case document
    }

    static func status(source: String, target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
        )
    }

    static func isInstalled(source: String, target: String) async -> Bool {
        await status(source: source, target: target) == .installed
    }

    static func installedSession(source: String, target: String, purpose: Purpose) async -> TranslationSession? {
        guard await isInstalled(source: source, target: target) else { return nil }
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        if #available(iOS 26.4, *) {
            // highFidelity uses Apple Intelligence models where they support the pair, else falls back.
            return TranslationSession(installedSource: from, target: to, preferredStrategy: purpose == .live ? .lowLatency : .highFidelity)
        }
        return TranslationSession(installedSource: from, target: to)
    }

    /// Translates phrases in batches and stores the result in `translation`.
    static func translate(_ segments: [TranscriptSegment], with session: TranslationSession) async throws {
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.uid.uuidString, $0) })
        let requests = segments.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.uid.uuidString) }
        for start in stride(from: 0, to: requests.count, by: 32) {
            try Task.checkCancellation()
            let responses = try await session.translations(from: Array(requests[start..<min(start + 32, requests.count)]))
            for response in responses {
                if let id = response.clientIdentifier { byID[id]?.translation = response.targetText }
            }
        }
    }

    /// Translates Markdown line by line, keeping heading marks, list markers and [hh:mm:ss] stamps
    /// out of the translator's reach.
    static func translateMarkdown(_ text: String, with session: TranslationSession) async throws -> String {
        let stamp = #/\s*\[\d{2}:\d{2}:\d{2}\]/#
        var lines = text.components(separatedBy: "\n")
        var parts: [Int: (prefix: String, stamps: String)] = [:]
        var requests: [TranslationSession.Request] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "---" else { continue }
            let prefix = markdownPrefix(of: line)
            var body = String(line.dropFirst(prefix.count))
            let stamps = body.matches(of: stamp)
                .map { String(body[$0.range]).trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            body = body.replacing(stamp, with: "")
            guard body.contains(where: \.isLetter) else { continue }
            parts[index] = (prefix, stamps)
            requests.append(TranslationSession.Request(sourceText: body, clientIdentifier: String(index)))
        }
        guard !requests.isEmpty else { return text }
        for start in stride(from: 0, to: requests.count, by: 24) {
            let responses = try await session.translations(from: Array(requests[start..<min(start + 24, requests.count)]))
            for response in responses {
                guard let raw = response.clientIdentifier, let index = Int(raw), let part = parts[index] else { continue }
                lines[index] = part.prefix + response.targetText + (part.stamps.isEmpty ? "" : " " + part.stamps)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Leading spaces plus "## ", "- ", "* " or "12. ".
    private static func markdownPrefix(of line: String) -> String {
        let leading = String(line.prefix { $0 == " " })
        let rest = line.dropFirst(leading.count)
        if rest.hasPrefix("#") {
            let hashes = String(rest.prefix { $0 == "#" })
            return leading + hashes + (rest.dropFirst(hashes.count).hasPrefix(" ") ? " " : "")
        }
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            return leading + String(rest.prefix(2))
        }
        let digits = String(rest.prefix { $0.isNumber })
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return leading + digits + ". "
        }
        return leading
    }
}
