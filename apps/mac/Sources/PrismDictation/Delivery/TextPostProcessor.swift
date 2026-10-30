// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import Foundation

/// Whitespace cleanup and vocabulary spelling normalization.
enum TextPostProcessor {
    static func clean(_ text: String, vocabulary: [String]) -> String {
        var result = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        for preferred in vocabulary where !preferred.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: preferred)
            let template = NSRegularExpression.escapedTemplate(for: preferred)
            result = result.replacingOccurrences(of: "(?i)(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", with: template, options: .regularExpression)
        }
        return result
    }
}
