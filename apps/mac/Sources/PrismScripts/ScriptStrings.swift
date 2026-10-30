import AppKit
import Foundation

enum ScriptStrings {
    /// Translates an English product message from the registry, including stored history errors. Messages with a
    /// number use a `%lld` key and messages with an OS detail after ": " use a `%@` key.
    static func localize(_ english: String) -> String {
        let bundle = Bundle.module
        let direct = bundle.localizedString(forKey: english, value: nil, table: nil)
        if direct != english { return direct }
        // The last number is the parameter: "Argument 2 is required.", "between 1 and 3600 seconds".
        if let range = english.ranges(of: /\d+/).last, let number = Int64(english[range]) {
            let key = english.replacingCharacters(in: range, with: "%lld")
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)
            if format != key { return String(format: format, number) }
        }
        if let range = english.range(of: ": ") {
            let key = english[..<range.lowerBound] + ": %@"
            let format = bundle.localizedString(forKey: String(key), value: nil, table: nil)
            if format != key { return String(format: format, String(english[range.upperBound...])) }
        }
        return english
    }

    static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}

/// Script output formatting: ANSI colors for the output view and one-line summaries for HUDs and inline rows.
enum ScriptOutput {
    /// The first non-empty line, as Raycast shows for inline commands.
    static func firstLine(_ text: String) -> String? {
        plain(text).split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// The last non-empty line, as Raycast shows for compact and silent commands.
    static func lastLine(_ text: String) -> String? {
        plain(text).split(whereSeparator: \.isNewline).reversed().lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    static func truncated(_ text: String, to limit: Int = 140) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// Removes ANSI escape sequences.
    static func plain(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return segments(text).map(\.text).joined()
    }

    struct Style: Equatable {
        var color: Int?
        var bold = false
        var dim = false
        var underline = false
    }

    struct Segment {
        var text: String
        var style: Style
    }

    /// Splits text at CSI sequences, applying SGR codes and dropping everything else.
    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var style = Style()
        var current = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\u{1B}" else { current.append(scalar); continue }
            guard scalars.first == "[" else {
                // A lone escape or a non-CSI sequence: drop the escape and its next character.
                _ = scalars.popFirst()
                continue
            }
            scalars.removeFirst()
            var parameters = ""
            var final: Unicode.Scalar?
            while let next = scalars.popFirst() {
                if (0x40...0x7E).contains(next.value) { final = next; break }
                parameters.unicodeScalars.append(next)
            }
            guard final == "m" else { continue }
            if !current.isEmpty { segments.append(Segment(text: String(current), style: style)); current = String.UnicodeScalarView() }
            apply(parameters, to: &style)
        }
        if !current.isEmpty { segments.append(Segment(text: String(current), style: style)) }
        return segments
    }

    private static func apply(_ parameters: String, to style: inout Style) {
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 24: style.underline = false
            case 30...37: style.color = code - 30
            case 90...97: style.color = code - 90 + 8
            case 39: style.color = nil
            case 38:
                // 38;5;n picks from the 256-color table; only its first 16 entries map to named colors.
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    style.color = codes[index + 2] < 16 ? codes[index + 2] : nil
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    static func color(_ index: Int) -> NSColor {
        switch index % 8 {
        case 0: index >= 8 ? .secondaryLabelColor : .labelColor
        case 1: .systemRed
        case 2: .systemGreen
        case 3: .systemYellow
        case 4: .systemBlue
        case 5: .systemPurple
        case 6: .systemTeal
        default: index >= 8 ? .labelColor : .secondaryLabelColor
        }
    }

    static func attributed(_ text: String, font: NSFont, baseColor: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for segment in segments(text) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: segment.style.bold ? bold : font,
                .foregroundColor: segment.style.color.map(color) ?? (segment.style.dim ? .secondaryLabelColor : baseColor),
            ]
            if segment.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }
}
