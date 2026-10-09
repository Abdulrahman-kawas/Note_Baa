import SwiftUI

/// Renders the Markdown the summarizers produce: headings, bullets, numbered items, paragraphs,
/// with inline bold/italic/code. Each block takes its own text direction.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(from: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(marker: String, text: String)
        case paragraph(String)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level == 1 ? 4 : 10)
                .textDirection(rightToLeft: text.isMostlyRTL)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 18)
            .textDirection(rightToLeft: text.isMostlyRTL)
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .textDirection(rightToLeft: text.isMostlyRTL)
        case .paragraph(let text):
            inline(text)
                .textDirection(rightToLeft: text.isMostlyRTL)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let indent = rawLine.prefix { $0 == " " }.count / 2
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(level: min(level, 3), text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(indent: indent, text: String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(marker: String(line[...dot]), text: rest))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }
}
