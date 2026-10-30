import AppKit
import PrismKit
import SwiftUI

/// Inline Markdown (emphasis, code, links, strikethrough) through Foundation's parser. Images become labels and inline
/// HTML tags are dropped, so nothing remote is fetched.
enum MarkdownInline {
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let tagPattern = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)

    static func attributed(_ source: String, size: CGFloat = MarkdownStyle.bodySize, codeBackground: Color = PrismTheme.surfaceStrong) -> AttributedString {
        var text = source
        let full = { NSRange(text.startIndex..., in: text) }
        text = imagePattern.stringByReplacingMatches(in: text, range: full(), withTemplate: "[\(L("Image")): $1]")
            .replacingOccurrences(of: "[\(L("Image")): ]", with: "[\(L("Image"))]")
        text = tagPattern.stringByReplacingMatches(in: text, range: full(), withTemplate: "")
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                // `.ai-markdown code`: 0.9 em monospace on a faint surface.
                result[run.range].font = .system(size: (size * 0.9).rounded(), design: .monospaced)
                result[run.range].backgroundColor = codeBackground
            }
        }
        linkify(&result)
        return result
    }

    /// GFM-style bare URL links in plain text runs.
    private static func linkify(_ text: inout AttributedString) {
        let plain = String(text.characters)
        let matches = urlPattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: plain), let url = URL(string: String(plain[range])) else { continue }
            let lower = text.index(text.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let upper = text.index(lower, offsetByCharacters: plain.distance(from: range.lowerBound, to: range.upperBound))
            let slice = text[lower..<upper]
            if slice.runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            text[lower..<upper].link = url
        }
        // `.ai-markdown a`: underlined in the accent color.
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
            text[run.range].foregroundColor = PrismTheme.accent
        }
    }
}

/// Parsed blocks cached by message text so scrolling and re-renders do not reparse long answers.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private final class Box {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    func blocks(for text: String) -> [MarkdownBlock] {
        if let box = cache.object(forKey: text as NSString) { return box.blocks }
        let blocks = MarkdownParser.parse(text)
        cache.setObject(Box(blocks), forKey: text as NSString, cost: text.utf8.count)
        return blocks
    }
}

/// Typography of the Tauri `.ai-markdown` answers: 14 pt on a 1.8 line height, 17 pt headings, 12 pt code.
enum MarkdownStyle {
    static let bodySize: CGFloat = 14
    static let lineHeight: CGFloat = 1.8
    static let codeSize: CGFloat = 12
    static let tableSize: CGFloat = 12
}

struct MarkdownView: View {
    let text: String
    var onCopyCode: (String) -> Void = { _ in }

    var body: some View {
        let blocks = MarkdownCache.shared.blocks(for: text)
        MarkdownBlocksView(blocks: blocks, onCopyCode: onCopyCode)
            .font(.system(size: MarkdownStyle.bodySize))
            .foregroundStyle(PrismTheme.text)
            .tint(PrismTheme.accent)
            .environment(\.openURL, OpenURLAction { url in
                // Only HTTP(S) links open, and only after a click.
                guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return .discarded }
                NSWorkspace.shared.open(url)
                return .handled
            })
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var onCopyCode: (String) -> Void
    var compact = false

    var body: some View {
        // Paragraphs are 12 pt apart (`margin: 0 0 12px`); list items 5 pt.
        VStack(alignment: .leading, spacing: compact ? 5 : 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, onCopyCode: onCopyCode, first: index == 0)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let onCopyCode: (String) -> Void
    var first = false

    var body: some View {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level <= 3 ? 17 : level == 4 ? 15 : 14
            Text(MarkdownInline.attributed(text, size: size))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(PrismTheme.text)
                .chatLineHeight(size, 1.4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, first ? 0 : 8)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .chatLineHeight(MarkdownStyle.bodySize, MarkdownStyle.lineHeight)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, onCopy: onCopyCode)
        case .quote(let blocks):
            // `.ai-markdown blockquote`
            MarkdownBlocksView(blocks: blocks, onCopyCode: onCopyCode)
                .foregroundStyle(PrismTheme.textSecondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(PrismTheme.accent).frame(width: 3) }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(checked ? PrismTheme.accent : PrismTheme.textMuted)
                            } else {
                                Text(verbatim: ordered ? "\(start + index)." : "•")
                                    .foregroundStyle(PrismTheme.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(width: 24, alignment: ordered ? .trailing : .center)
                        .padding(.trailing, ordered ? 6 : 0)
                        MarkdownBlocksView(blocks: item.blocks, onCopyCode: onCopyCode, compact: true)
                    }
                }
            }
            .padding(.vertical, 2)
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows)
        case .rule:
            Rectangle().fill(PrismTheme.lineStrong).frame(height: 1).padding(.vertical, 4)
        }
    }
}

/// `.ai-code-block`: a faint well with the copy button in its top-right corner.
private struct CodeBlockView: View {
    let language: String
    let code: String
    let onCopy: (String) -> Void
    @ViewState private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: code)
                .font(.system(size: MarkdownStyle.codeSize, design: .monospaced))
                .foregroundStyle(PrismTheme.text)
                .chatLineHeight(MarkdownStyle.codeSize, 1.6)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 32)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.line))
        .overlay(alignment: .topLeading) {
            if !language.isEmpty {
                Text(verbatim: language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(PrismTheme.textMuted)
                    .padding(.leading, 14)
                    .padding(.top, 11)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onCopy(code)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .frame(width: 13, height: 13)
                    .padding(5)
            }
            .buttonStyle(ChatButtonStyle(fill: PrismTheme.surfaceStrong, radius: 5))
            .help(L("Copy code"))
            .accessibilityLabel(copied ? L("Copied") : L("Copy code"))
            .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// `.ai-markdown table`: 12 pt cells with hairline borders.
private struct TableBlockView: View {
    let header: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column).fontWeight(.semibold)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row].indices.contains(column) ? rows[row][column] : "", column: column)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(PrismTheme.lineStrong))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        Text(MarkdownInline.attributed(text, size: MarkdownStyle.tableSize))
            .font(.system(size: MarkdownStyle.tableSize))
            .foregroundStyle(PrismTheme.text)
            .frame(maxWidth: 320, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .overlay(Rectangle().stroke(PrismTheme.lineStrong, lineWidth: 0.5))
            .gridColumnAlignment(alignment.horizontal)
    }
}
