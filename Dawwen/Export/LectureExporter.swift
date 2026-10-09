import AVFoundation
import Foundation

/// Builds the files a student takes elsewhere: plain text, Markdown, SRT subtitles, and the audio.
@MainActor
enum LectureExporter {
    enum Format: String, CaseIterable, Identifiable {
        case text, markdown, srt, srtTranslated, audio

        var id: String { rawValue }

        var title: String {
            switch self {
            case .text: "نص (TXT)"
            case .markdown: "Markdown مع الملخص"
            case .srt: "ترجمة مرئية SRT (الأصل)"
            case .srtTranslated: "ترجمة مرئية SRT (المترجَم)"
            case .audio: "الصوت (M4A)"
            }
        }

        var systemImage: String {
            switch self {
            case .text: "doc.plaintext"
            case .markdown: "doc.richtext"
            case .srt, .srtTranslated: "captions.bubble"
            case .audio: "waveform"
            }
        }
    }

    static func export(_ lecture: Lecture, as format: Format) async throws -> URL {
        let name = fileName(for: lecture)
        switch format {
        case .text: return try write(text(for: lecture), name: name, ext: "txt")
        case .markdown: return try write(markdown(for: lecture), name: name, ext: "md")
        case .srt: return try write(srt(for: lecture, translated: false), name: name, ext: "srt")
        case .srtTranslated: return try write(srt(for: lecture, translated: true), name: name + "-translated", ext: "srt")
        case .audio: return try await audio(for: lecture, name: name)
        }
    }

    static func text(for lecture: Lecture) -> String {
        var lines = [lecture.title, lecture.createdAt.formatted(date: .long, time: .shortened), ""]
        for segment in lecture.sortedSegments {
            lines.append("\(TimeFormat.stamp(segment.start)) \(segment.text)")
            if let translation = segment.translation { lines.append("    \(translation)") }
        }
        return lines.joined(separator: "\n")
    }

    static func markdown(for lecture: Lecture) -> String {
        var parts = [
            "# \(lecture.title)",
            "",
            "- التاريخ: \(lecture.createdAt.formatted(date: .long, time: .shortened))",
            "- المدة: \(TimeFormat.duration(lecture.duration))",
            "- اللغة: \(Languages.name(for: lecture.sourceLanguage))",
            ""
        ]
        if let summary = lecture.summary {
            parts += ["## الملخص", "", summary, ""]
        }
        parts += ["## النص الكامل", ""]
        for segment in lecture.sortedSegments {
            var line = "**\(TimeFormat.stamp(segment.start))** \(segment.text)"
            if let translation = segment.translation { line += "\n> \(translation)" }
            parts += [line, ""]
        }
        return parts.joined(separator: "\n")
    }

    static func srt(for lecture: Lecture, translated: Bool) -> String {
        var cues: [String] = []
        for (index, segment) in lecture.sortedSegments.enumerated() {
            let body = translated ? (segment.translation ?? segment.text) : segment.text
            let end = max(segment.end, segment.start + 1)
            cues.append("\(index + 1)\n\(TimeFormat.srt(segment.start)) --> \(TimeFormat.srt(end))\n\(body)\n")
        }
        return cues.joined(separator: "\n")
    }

    private static func audio(for lecture: Lecture, name: String) async throws -> URL {
        let (composition, _) = await LecturePlayer.makeComposition(urls: LectureStore.audioURLs(for: lecture))
        let url = FileManager.default.temporaryDirectory.appending(path: name + ".m4a")
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await session.export(to: url, as: .m4a)
        return url
    }

    private static func write(_ content: String, name: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func fileName(for lecture: Lecture) -> String {
        let cleaned = lecture.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.isEmpty ? "lecture" : String(cleaned.prefix(80))
    }
}
