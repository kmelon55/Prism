import Foundation

/// A small CommonMark/GFM block parser for chat answers: headings, paragraphs, lists (nested, ordered, tasks),
/// block quotes, fenced code, tables and rules. Raw HTML is skipped. Inline syntax is left as source text and
/// rendered by `MarkdownInline`. Tolerates partial input while an answer streams.
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, code: String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case rule
}

struct MarkdownListItem: Equatable, Sendable {
    var checked: Bool?
    var blocks: [MarkdownBlock]
}

enum MarkdownAlignment: Equatable, Sendable { case leading, center, trailing }

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parse(lines: lines[...], depth: 0)
    }

    private static func parse(lines: ArraySlice<String>, depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = lines.startIndex

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            if indent < 4, let fence = fenceOpening(trimmed) {
                flush()
                var code: [String] = []
                index += 1
                while index < lines.endIndex {
                    let current = lines[index]
                    let closing = current.trimmingCharacters(in: .whitespaces)
                    if leadingSpaces(current) < 4, closing.allSatisfy({ $0 == fence.character }), closing.count >= fence.length {
                        index += 1
                        break
                    }
                    code.append(String(current.dropFirst(min(indent, leadingSpaces(current)))))
                    index += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                continue
            }
            if indent < 4, let heading = atxHeading(trimmed) {
                flush()
                blocks.append(heading)
                index += 1
                continue
            }
            if indent < 4, !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                paragraph.removeAll()
                blocks.append(.heading(level: level, text: text))
                index += 1
                continue
            }
            if indent < 4, isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            if indent < 4, isHTMLBlock(trimmed) {
                flush()
                index += 1
                continue
            }
            if indent < 4, trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while index < lines.endIndex {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if current.hasPrefix(">") {
                        var content = current.dropFirst()
                        if content.first == " " { content = content.dropFirst() }
                        inner.append(String(content))
                    } else if !current.isEmpty, !inner.isEmpty, !(inner.last ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                              startsBlock(current) == false {
                        inner.append(current) // Lazy continuation of a quoted paragraph.
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.quote(depth < 8 ? parse(lines: inner[...], depth: depth + 1) : [.paragraph(inner.joined(separator: "\n"))]))
                continue
            }
            if indent < 4, let marker = listMarker(line) {
                flush()
                let (list, next) = parseList(lines, from: index, first: marker, depth: depth)
                blocks.append(list)
                index = next
                continue
            }
            if indent < 4, line.contains("|"), index + 1 < lines.endIndex, let alignments = delimiterRow(lines[index + 1]) {
                let header = cells(line)
                if header.count == alignments.count {
                    flush()
                    var rows: [[String]] = []
                    index += 2
                    while index < lines.endIndex {
                        let row = lines[index]
                        if row.trimmingCharacters(in: .whitespaces).isEmpty || !row.contains("|") { break }
                        var values = cells(row)
                        if values.count < header.count { values += Array(repeating: "", count: header.count - values.count) }
                        rows.append(Array(values.prefix(header.count)))
                        index += 1
                    }
                    blocks.append(.table(header: header, alignments: alignments, rows: rows))
                    continue
                }
            }
            if !paragraph.isEmpty || indent < 4 || depth > 0 {
                paragraph.append(line)
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    // MARK: Lists

    struct ListMarker {
        var ordered: Bool
        var number: Int
        var bullet: Character
        /// Column where the item's content starts.
        var contentOffset: Int
        var content: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        guard indent < 4 + 0 || true else { return nil }
        let rest = Substring(line.dropFirst(indent))
        guard let first = rest.first else { return nil }
        var markerLength: Int
        var ordered = false
        var number = 1
        if "-*+".contains(first) {
            markerLength = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
            markerLength = digits.count + 1
            ordered = true
            number = Int(digits) ?? 1
        } else {
            return nil
        }
        let afterMarker = rest.dropFirst(markerLength)
        if afterMarker.isEmpty {
            return ListMarker(ordered: ordered, number: number, bullet: ordered ? "." : first, contentOffset: indent + markerLength + 1, content: "")
        }
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let spaces = min(afterMarker.prefix { $0 == " " }.count, 4)
        let content = String(afterMarker.dropFirst(max(spaces, 1)))
        if !ordered, isRule(line.trimmingCharacters(in: .whitespaces)) { return nil }
        return ListMarker(ordered: ordered, number: number, bullet: ordered ? Array(rest.dropFirst(markerLength - 1)).first ?? "." : first,
                          contentOffset: indent + markerLength + max(spaces, 1), content: content)
    }

    private static func parseList(_ lines: ArraySlice<String>, from start: Int, first: ListMarker, depth: Int) -> (MarkdownBlock, Int) {
        var items: [MarkdownListItem] = []
        var index = start
        var marker = first
        let baseIndent = leadingSpaces(lines[start])
        while true {
            var itemLines = [marker.content]
            index += 1
            var sawBlank = false
            while index < lines.endIndex {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    sawBlank = true
                    itemLines.append("")
                    index += 1
                    continue
                }
                let indent = leadingSpaces(line)
                if indent >= marker.contentOffset || (indent > baseIndent && listMarker(line) != nil) {
                    itemLines.append(String(line.dropFirst(min(indent, marker.contentOffset))))
                    sawBlank = false
                    index += 1
                    continue
                }
                if let next = listMarker(line), indent <= baseIndent + 1, next.ordered == first.ordered,
                   next.bullet == first.bullet || first.ordered {
                    break
                }
                if !sawBlank, !startsBlock(trimmed) {
                    itemLines.append(trimmed) // Lazy paragraph continuation.
                    index += 1
                    continue
                }
                break
            }
            while itemLines.last?.isEmpty == true { itemLines.removeLast() }
            var checked: Bool?
            if let head = itemLines.first {
                for (prefix, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where head.hasPrefix(prefix) {
                    checked = value
                    itemLines[0] = String(head.dropFirst(prefix.count))
                }
            }
            let blocks = depth < 8 ? parse(lines: itemLines[...], depth: depth + 1) : [.paragraph(itemLines.joined(separator: "\n"))]
            items.append(MarkdownListItem(checked: checked, blocks: blocks))
            guard index < lines.endIndex, let next = listMarker(lines[index]), leadingSpaces(lines[index]) <= baseIndent + 1,
                  next.ordered == first.ordered, next.bullet == first.bullet || first.ordered else { break }
            marker = next
        }
        return (.list(ordered: first.ordered, start: first.number, items: items), index)
    }

    // MARK: Line classification

    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 - count % 4 } else { break }
        }
        return count
    }

    private static func startsBlock(_ trimmed: String) -> Bool {
        fenceOpening(trimmed) != nil || atxHeading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">") || listMarker(trimmed) != nil
    }

    private static func fenceOpening(_ trimmed: String) -> (character: Character, length: Int, language: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return (first, length, String(info.split(separator: " ").first ?? ""))
    }

    private static func atxHeading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##".
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) } else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return .heading(level: level, text: text)
    }

    private static func setextLevel(_ trimmed: String) -> Int? {
        if trimmed.count >= 1, trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isHTMLBlock(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*(\s[^>]*)?/?>"#, options: .regularExpression) != nil
            || trimmed.hasPrefix("<!--")
    }

    // MARK: Tables

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func delimiterRow(_ line: String) -> [MarkdownAlignment]? {
        guard line.contains("-") else { return nil }
        let values = cells(line)
        var alignments: [MarkdownAlignment] = []
        for value in values {
            guard value.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            alignments.append(value.hasPrefix(":") && value.hasSuffix(":") ? .center : value.hasSuffix(":") ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }
}
