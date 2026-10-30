import Foundation

/// A small wrapper over `NSRegularExpression` so the Tauri app's JavaScript patterns port verbatim.
/// Patterns use `[0-9]` instead of `\d` because ICU's `\d` also matches non-ASCII digits.
struct Pattern: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // Every pattern is a compile-time literal, so a failure is a programming error.
        expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Capture groups of the first match; index 0 is the whole match. Unmatched optional groups are nil.
    func match(_ text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let result = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Replaces every match with `transform(groups)`.
    func replace(in text: String, _ transform: ([String?]) -> String) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        for result in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: result.range.location - cursor))
            let groups = (0..<result.numberOfRanges).map { index -> String? in
                let range = result.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            output += transform(groups)
            cursor = result.range.location + result.range.length
        }
        return output + source.substring(from: cursor)
    }
}

extension String {
    /// JavaScript's `String.prototype.trim`, which also removes Unicode spaces and line terminators.
    var jsTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Matches the Tauri providers' `/[\u0000-\u001f\u007f]/` guard.
    var containsControlCharacter: Bool {
        unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
