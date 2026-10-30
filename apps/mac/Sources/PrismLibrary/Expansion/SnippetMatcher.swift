import Foundation

/// One expandable snippet. Template snippets (`{date}`, `{time}`, `{clipboard}`) are never registered.
struct ExpansionSnippet: Equatable, Sendable {
    var keyword: String
    var text: String
}

enum SnippetRegistry {
    static let maxSnippets = 1000

    /// Ported from `registry` in `snippet_expansion.rs`: valid keywords on nonempty, non-template snippets.
    /// Every keyword that appears twice is dropped entirely.
    static func build(_ entries: [LibraryEntry]) -> [ExpansionSnippet] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        var result: [ExpansionSnippet] = []
        for entry in entries.prefix(maxSnippets) {
            guard entry.kind == .snippet, let keyword = entry.keyword, LibraryValidation.isValidKeyword(keyword),
                  !entry.value.isEmpty, entry.value.utf8.count <= LibraryLimits.maxEntryBytes,
                  !LibraryTemplate.snippetPlaceholders.contains(where: { entry.value.contains($0) })
            else { continue }
            if !seen.insert(keyword).inserted { duplicates.insert(keyword) }
            result.append(ExpansionSnippet(keyword: keyword, text: entry.value))
        }
        return result.filter { !duplicates.contains($0.keyword) }
    }
}

/// Matches typed keys against keywords, ported from `Matcher` in `snippet_expansion.rs`. It keeps only candidate
/// indexes and a position, never the typed text. A delimiter right after a complete keyword returns its index.
struct SnippetMatcher {
    static let delimiters: Set<Character> = [" ", "\t", "\n"]
    static let maxKeyword = 48

    private(set) var candidates: [Int] = []
    private(set) var position = 0

    var isIdle: Bool { position == 0 }

    mutating func reset() {
        candidates.removeAll(keepingCapacity: true)
        position = 0
    }

    /// Feeds one typed character. `safe` is false when the context cannot expand (IME, secure input, …).
    mutating func feed(_ key: Character, snippets: [ExpansionSnippet], safe: Bool) -> Int? {
        guard safe else {
            reset()
            return nil
        }
        if Self.delimiters.contains(key) {
            let found = candidates.first { snippets[$0].keyword.utf8.count == position }
            reset()
            return found
        }
        if !key.isASCII || position >= Self.maxKeyword { reset() }
        if position > 0, let byte = key.asciiValue {
            candidates.removeAll { index in
                let bytes = snippets[index].keyword.utf8
                return bytes.count <= position || bytes[bytes.index(bytes.startIndex, offsetBy: position)] != byte
            }
            position += 1
            if candidates.isEmpty { reset() }
        }
        if position == 0, let byte = key.asciiValue, LibraryValidation.keywordPrefixes.contains(byte) {
            candidates = snippets.indices.filter { snippets[$0].keyword.utf8.first == byte }
            position = 1
        }
        return nil
    }
}

/// Context checks before matching and before replacing. Every one must pass.
struct ExpansionGuards: Equatable {
    var enabled = true
    var permissions = true
    var directInput = true
    var secure = false
    var excluded = false
    var synthetic = false
    var focusMatches = true

    var isSafe: Bool { enabled && permissions && directInput && !secure && !excluded && !synthetic && focusMatches }
}

/// Persisted in `snippet-expansion-v1.json`, the same file and keys as the Tauri app.
struct SnippetExpansionConfig: Codable, Equatable, Sendable {
    var enabled = false
    var excludedApps: [String] = []

    static let fileName = "snippet-expansion-v1.json"
    static let maxExclusions = 100

    /// Prism, login and security windows and password managers are never expanded into.
    static let alwaysExcluded: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.agilebits.onepassword7", "com.1password.1password",
        "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess", "dev.prism.desktop", "dev.prism.native-dev",
    ]

    static func isValidExclusion(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID.utf8.count <= 255
            && bundleID.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "._-".utf8.contains(byte)
            }
    }

    var isValid: Bool { excludedApps.count <= Self.maxExclusions && excludedApps.allSatisfy(Self.isValidExclusion) }

    func excludes(_ bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return Self.alwaysExcluded.contains(bundleID) || bundleID == Bundle.main.bundleIdentifier || excludedApps.contains(bundleID)
    }
}
