import Foundation

public enum TextMatching {
    /// Compatibility width, case and accent folding while preserving whole Hangul syllables.
    public static func normalize(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(scalar) {
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// Scores `needle` as an ordered subsequence of `haystack`. Both are expected to be normalized.
    public static func subsequenceScore(_ needle: String, _ haystack: String) -> Double? {
        let characters = Array(haystack.unicodeScalars)
        let needleCount = needle.unicodeScalars.count
        var score = 0.0
        var cursor = 0
        var streak = 0
        for character in needle.unicodeScalars {
            var index = cursor
            while index < characters.count && !matches(character, characters[index]) { index += 1 }
            if index == characters.count { return nil }
            let isBoundary = index == 0 || isBoundaryScalar(characters[index - 1])
            streak = index == cursor ? streak + 1 : 0
            score += Double(14 + streak * 5 + (isBoundary ? 12 : 0) - min(index - cursor, 9))
            cursor = index + 1
        }
        return score - Double(max(characters.count - needleCount, 0)) * 0.08
    }

    /// A typed leading Jamo may stand for a syllable; full syllables still match literally.
    private static func matches(_ needle: Unicode.Scalar, _ candidate: Unicode.Scalar) -> Bool {
        if needle == candidate { return true }
        let initial = needle.value
        let syllable = candidate.value
        return (0x1100...0x1112).contains(initial) && (0xAC00...0xD7A3).contains(syllable)
            && (syllable - 0xAC00) / 588 == initial - 0x1100
    }

    private static func isBoundaryScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || "_-./".unicodeScalars.contains(scalar)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}
