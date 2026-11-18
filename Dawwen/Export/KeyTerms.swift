import Foundation
import Observation
import SwiftData
import UIKit

/// The lecture's key terms and words as an Excel sheet to study from. The ask model picks them out
/// over the same cached transcript Ask AI reads, and the list is kept in the lecture folder until the
/// student deletes it or asks for a new one.
@MainActor
enum KeyTerms {
    struct Item: Codable {
        var term: String
        /// "term" (technical) or "word" (general vocabulary).
        var kind: String
        var translation: String
        var meaning: String
        var example: String
        var time: String
    }

    enum KeyTermsError: LocalizedError {
        case noTranscript
        case noTerms

        var errorDescription: String? {
            switch self {
            case .noTranscript: "This lecture has no transcript yet."
            case .noTerms: "The model didn't return any terms. Try again."
            }
        }
    }

    static let outputSchema = #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"term":{"type":"string"},"kind":{"type":"string","enum":["term","word"]},"translation":{"type":"string"},"meaning":{"type":"string"},"example":{"type":"string"},"time":{"type":"string"}},"required":["term","kind","translation","meaning","example","time"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}"#

    private struct Reply: Decodable {
        let items: [Item]
    }

    /// The saved list, in the language it was made in.
    struct Saved: Codable {
        let language: String
        let madeAt: Date
        let items: [Item]
    }

    static let fileName = "key-terms.json"

    static func listURL(for lectureID: UUID) -> URL {
        LectureStore.folder(for: lectureID).appending(path: fileName)
    }

    /// The saved list as an .xlsx in tmp, made first if there is none.
    static func export(_ lecture: Lecture) async throws -> URL {
        let saved: Saved
        if let existing = load(lecture.id) { saved = existing } else { saved = try await make(lecture) }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(LectureExporter.fileName(for: lecture)) - \(Labels(saved.language).sheet).xlsx")
        try XLSXWriter.data(for: sheet(for: lecture, items: saved.items, language: saved.language)).write(to: url, options: .atomic)
        return url
    }

    static func delete(lectureID: UUID) {
        try? FileManager.default.removeItem(at: listURL(for: lectureID))
    }

    private static func load(_ lectureID: UUID) -> Saved? {
        guard let data = try? Data(contentsOf: listURL(for: lectureID)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    // MARK: - The list

    /// Asks the model for a new list and saves it over the old one.
    @discardableResult
    static func make(_ lecture: Lecture) async throws -> Saved {
        let segments = lecture.sortedSegments
        guard !segments.isEmpty else { throw KeyTermsError.noTranscript }
        let settings = AppSettings.current
        // The language Ask AI answers in: the lecture's translation language unless one is fixed.
        let language = settings.answerLanguage(lectureTarget: lecture.targetLanguage)
        let model = settings.askModel.resolved()
        guard let client = model.client() else { throw model.missingKeyError }
        // The glossary is written for the translation language; it only helps when that's the sheet's.
        let glossary = Languages.code(language) == Languages.code(settings.targetLanguage) ? settings.glossary : []
        let request = ClaudeClient.Request(
            preamble: LecturePrompt.preamble(for: lecture),
            context: LecturePrompt.transcript(for: lecture),
            userMessage: LecturePrompt.keyTermsRequest(lectureLanguage: lecture.sourceLanguage,
                                                       readingLanguage: language, glossary: glossary),
            effort: "medium",
            maxTokens: 16_000,
            outputSchema: outputSchema
        )
        let json = try await client.complete(request)
        let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))

        var seen = Set<String>()
        let items = reply.items.compactMap { item -> Item? in
            var item = item
            item.term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            item.time = item.time.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            guard !item.term.isEmpty, seen.insert(item.term.lowercased()).inserted else { return nil }
            return item
        }
        // In the order they came up; entries without a time go last.
        .enumerated()
        .sorted { (seconds($0.element.time) ?? .infinity, $0.offset) < (seconds($1.element.time) ?? .infinity, $1.offset) }
        .map(\.element)
        guard !items.isEmpty else { throw KeyTermsError.noTerms }

        let saved = Saved(language: language, madeAt: .now, items: items)
        // Deleted while the model was answering: nothing to save it with.
        guard !lecture.isDeleted, lecture.modelContext != nil else { return saved }
        try LectureStore.createFolder(for: lecture.id)
        try JSONEncoder().encode(saved).write(to: listURL(for: lecture.id), options: .atomic)
        return saved
    }

    /// "01:02:03" or "02:03" → seconds.
    private static func seconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count), parts.count == time.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: - The sheet

    private static func sheet(for lecture: Lecture, items: [Item], language: String) -> XLSXWriter.Sheet {
        let labels = Labels(language)
        let translated = Languages.code(language) != Languages.code(lecture.sourceLanguage)
        var columns: [XLSXWriter.Column] = [.init(header: labels.number, width: 5), .init(header: labels.term, width: 26)]
        if translated { columns.append(.init(header: labels.translation, width: 26)) }
        columns += [
            .init(header: labels.kind, width: 11),
            .init(header: labels.meaning, width: 52),
            .init(header: labels.example, width: 52),
            .init(header: labels.time, width: 11)
        ]
        let rows = items.enumerated().map { index, item -> [XLSXWriter.Cell] in
            var row: [XLSXWriter.Cell] = [.number(index + 1), .strong(item.term)]
            if translated { row.append(.text(item.translation)) }
            row += [
                .centered(item.kind == "word" ? labels.word : labels.technical),
                .text(item.meaning),
                .text(item.example),
                .centered(item.time)
            ]
            return row
        }
        let date = lecture.createdAt.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: language)))
        return XLSXWriter.Sheet(name: labels.sheet, title: "\(lecture.title) · \(date)", columns: columns, rows: rows,
                                rightToLeft: Languages.isRTL(language))
    }

    /// Column names in the language the sheet is read in.
    private struct Labels {
        let sheet, number, term, translation, kind, meaning, example, time, technical, word: String

        init(_ language: String) {
            switch Languages.code(language) {
            case "ar":
                (sheet, number, term, translation, kind) = ("المصطلحات", "#", "المصطلح", "الترجمة", "النوع")
                (meaning, example, time, technical, word) = ("المعنى", "من المحاضرة", "الوقت", "مصطلح", "كلمة")
            case "ru":
                (sheet, number, term, translation, kind) = ("Термины", "№", "Термин", "Перевод", "Тип")
                (meaning, example, time, technical, word) = ("Значение", "Из лекции", "Время", "Термин", "Слово")
            case "fr":
                (sheet, number, term, translation, kind) = ("Termes clés", "N°", "Terme", "Traduction", "Type")
                (meaning, example, time, technical, word) = ("Sens", "Dans le cours", "Moment", "Terme", "Mot")
            case "de":
                (sheet, number, term, translation, kind) = ("Fachbegriffe", "Nr.", "Begriff", "Übersetzung", "Art")
                (meaning, example, time, technical, word) = ("Bedeutung", "Aus der Vorlesung", "Zeit", "Fachbegriff", "Wort")
            case "es":
                (sheet, number, term, translation, kind) = ("Términos clave", "N.º", "Término", "Traducción", "Tipo")
                (meaning, example, time, technical, word) = ("Significado", "En la clase", "Minuto", "Término", "Palabra")
            case "tr":
                (sheet, number, term, translation, kind) = ("Terimler", "No", "Terim", "Çeviri", "Tür")
                (meaning, example, time, technical, word) = ("Anlamı", "Dersten", "Zaman", "Terim", "Kelime")
            default:
                (sheet, number, term, translation, kind) = ("Key terms", "#", "Term", "Translation", "Type")
                (meaning, example, time, technical, word) = ("Meaning", "From the lecture", "Time", "Term", "Word")
            }
        }
    }
}

/// Which lectures have a key terms list, which were made automatically and not opened yet (the red
/// mark in the library and on the lecture), and which are being made. A list is made after every
/// lecture; one cut short by the app going to the background is made the next time the app is open.
@MainActor
@Observable
final class KeyTermsStore {
    static let shared = KeyTermsStore()

    private(set) var ready: Set<UUID> = []
    private(set) var unseen: Set<UUID> = []
    private(set) var working: Set<UUID> = []

    /// For lists still owed after a lecture, found again at launch.
    @ObservationIgnored var container: ModelContainer?
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var backgroundTime: [UUID: UIBackgroundTaskIdentifier] = [:]

    private static let unseenKey = "keyTermsUnseen"
    private static let pendingKey = "keyTermsPending"

    private init() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: LectureStore.rootFolder, includingPropertiesForKeys: nil)) ?? []
        ready = Set(folders.compactMap { folder in
            FileManager.default.fileExists(atPath: folder.appending(path: KeyTerms.fileName).path)
                ? UUID(uuidString: folder.lastPathComponent) : nil
        })
        unseen = Self.ids(Self.unseenKey).intersection(ready)
        pending = Self.ids(Self.pendingKey)
    }

    /// Called when a recording ends.
    func makeAfterLecture(_ lecture: Lecture) {
        guard AppSettings.current.autoKeyTerms, !lecture.segments.isEmpty else { return }
        pending.insert(lecture.id)
        save()
        Task { try? await make(lecture, automatic: true) }
    }

    /// Lists owed from earlier lectures (the app went to the background or had no network).
    func resumePending() {
        guard !pending.isEmpty, let context = container?.mainContext else { return }
        for id in pending where !working.contains(id) {
            let lecture = try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate { $0.id == id })).first
            guard let lecture else {
                pending.remove(id)
                continue
            }
            Task { try? await make(lecture, automatic: true) }
        }
        save()
    }

    /// `automatic`: made after the lecture, so it gets the red mark and a notification.
    func make(_ lecture: Lecture, automatic: Bool) async throws {
        let id = lecture.id
        guard !working.contains(id) else { return }
        working.insert(id)
        // A few more seconds if the student leaves the app right after the lecture.
        backgroundTime[id] = UIApplication.shared.beginBackgroundTask(withName: "Key terms list") {
            MainActor.assumeIsolated { KeyTermsStore.shared.endBackgroundTime(id) }
        }
        defer {
            working.remove(id)
            endBackgroundTime(id)
        }
        do {
            try await KeyTerms.make(lecture)
        } catch {
            // No network or cut off in the background: try again next time. Anything else (no key,
            // no transcript) would fail the same way again.
            if !(error is URLError || error is CancellationError) { pending.remove(id) }
            save()
            throw error
        }
        pending.remove(id)
        guard !lecture.isDeleted, lecture.modelContext != nil else { return save() }
        ready.insert(id)
        if automatic {
            unseen.insert(id)
            RecordingAlerts.post("Key terms list ready", "“\(lecture.title)”: the Excel sheet is saved with the lecture.")
        }
        save()
    }

    func share(_ lecture: Lecture) async throws {
        let url = try await KeyTerms.export(lecture)
        ready.insert(lecture.id)
        markSeen(lecture.id)
        SharePresenter.share([url])
    }

    func markSeen(_ id: UUID) {
        guard unseen.remove(id) != nil else { return }
        save()
    }

    func delete(_ id: UUID) {
        KeyTerms.delete(lectureID: id)
        forget(id)
    }

    /// The lecture is gone (or only its list).
    func forget(_ id: UUID) {
        ready.remove(id)
        unseen.remove(id)
        pending.remove(id)
        save()
    }

    private func endBackgroundTime(_ id: UUID) {
        guard let token = backgroundTime.removeValue(forKey: id) else { return }
        UIApplication.shared.endBackgroundTask(token)
    }

    private func save() {
        UserDefaults.standard.set(unseen.map(\.uuidString), forKey: Self.unseenKey)
        UserDefaults.standard.set(pending.map(\.uuidString), forKey: Self.pendingKey)
    }

    private static func ids(_ key: String) -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
}
