import Foundation

/// Translate product messages only. Transcripts and provider responses stay untouched.
struct NativeMessages {
    private var entries: [String: [String]] = [:]
    private var templates: [(NSRegularExpression, [String], [String])] = []

    init(json: String = "[]") {
        guard let pairs = try? JSONDecoder().decode([[String]].self, from: Data(json.utf8)) else { return }
        let placeholder = try! NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        for pair in pairs where pair.count == 2 {
            for source in pair where entries[source] == nil {
                entries[source] = pair
                let matches = placeholder.matches(in: source, range: NSRange(source.startIndex..., in: source))
                guard !matches.isEmpty else { continue }
                var pattern = "^", names: [String] = [], cursor = source.startIndex
                for match in matches {
                    guard let range = Range(match.range, in: source) else { continue }
                    pattern += NSRegularExpression.escapedPattern(for: String(source[cursor..<range.lowerBound])) + "(.+?)"
                    names.append(String(source[range])); cursor = range.upperBound
                }
                pattern += NSRegularExpression.escapedPattern(for: String(source[cursor...])) + "$"
                if let regex = try? NSRegularExpression(pattern: pattern) { templates.append((regex, names, pair)) }
            }
        }
    }

    func translate(_ source: String, english: Bool) -> String {
        source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let pair = entries[trimmed] { return line.replacingOccurrences(of: trimmed, with: pair[english ? 0 : 1]) }
            for (regex, names, pair) in templates {
                guard let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { continue }
                var translated = pair[english ? 0 : 1]
                for (index, name) in names.enumerated() {
                    guard let range = Range(match.range(at: index + 1), in: trimmed) else { continue }
                    translated = translated.replacingOccurrences(of: name, with: String(trimmed[range]))
                }
                return line.replacingOccurrences(of: trimmed, with: translated)
            }
            return line
        }.joined(separator: "\n")
    }
}
