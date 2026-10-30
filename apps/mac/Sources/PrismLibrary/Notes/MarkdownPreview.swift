import SwiftUI

/// Block-level Markdown for the note preview: headings, paragraphs, bullet, numbered and task lists, quotes,
/// fenced code and GFM tables. Inline styles use Foundation's Markdown parser. Raw HTML stays literal text and
/// images show their alt text, as in the Tauri preview.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, marker: ListMarker, text: String)
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    enum ListMarker: Equatable {
        case bullet
        case number(String)
        case task(done: Bool)
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.components(separatedBy: .newlines)
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && trimmed.count >= 3 {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = Self.listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            } else if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(Self.cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        var text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        return .heading(level: hashes, text: text)
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count / 2
        let body = line.trimmingCharacters(in: .whitespaces)
        if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " {
            let text = String(body.dropFirst(2))
            for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
                return .listItem(indent: indent, marker: .task(done: done), text: String(text.dropFirst(prefix.count)))
            }
            return .listItem(indent: indent, marker: .bullet, text: text)
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = body.dropFirst(digits.count)
            if let separator = rest.first, separator == "." || separator == ")", rest.dropFirst().first == " " {
                return .listItem(indent: indent, marker: .number("\(digits)."), text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct MarkdownPreview: View {
    let source: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: [26, 21, 18, 16, 15, 14][level - 1], weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 14)).lineSpacing(3)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch marker {
                case .bullet: Text(verbatim: "•").foregroundStyle(.secondary)
                case .number(let number): Text(verbatim: number).foregroundStyle(.secondary).monospacedDigit()
                case .task(let done):
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                }
                Text(Self.inline(text))
                    .strikethrough(marker == .task(done: true), color: .secondary)
                    .foregroundStyle(marker == .task(done: true) ? .secondary : .primary)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Self.inline(text)).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text).font(.system(size: 12.5, design: .monospaced)).padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(Self.inline($0.element)).fontWeight(.semibold) } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(Self.inline($0.element)) } }
                }
            }
            .font(.system(size: 13))
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// Bold, italic, code, strikethrough and links. Images become their alt text; nothing loads from the network.
    static func inline(_ text: String) -> AttributedString {
        let withoutImages = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "[$1]", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: withoutImages, options: options)) ?? AttributedString(text)
        // Open only web links.
        for run in attributed.runs {
            if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributed[run.range].link = nil
            }
        }
        return attributed
    }
}
