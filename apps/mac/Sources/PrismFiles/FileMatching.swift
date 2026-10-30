import Foundation

/// Filename matching shared by Spotlight and the folder index, ported from `library/file_index.rs`.
enum FileSearchKey {
    /// NFKC and lowercase folding. Joins decomposed Hangul from older macOS filenames.
    static func make(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// Hidden names and dependency, build and cache folders are never indexed or shown.
    static func isExcluded(_ name: String) -> Bool {
        name.hasPrefix(".") || excludedNames.contains(name)
    }

    private static let excludedNames: Set<String> = [
        "node_modules", "target", "dist", "build", "Library", "vendor", "venv", "__pycache__", "Pods",
    ]
}

/// A filename query. Ranks are buckets: exact name, whole-query prefix, whole-query substring, all
/// whitespace tokens, then a bounded subsequence. Queries allow up to eight tokens and 512 bytes.
struct FilenameQuery: Sendable {
    let phrase: String
    private let tokens: [(text: String, characters: [Character])]
    private let valid: Bool

    init(_ query: String) {
        phrase = FileSearchKey.make(query.trimmingCharacters(in: .whitespacesAndNewlines))
        tokens = phrase.split(whereSeparator: \.isWhitespace).prefix(9).map { (String($0), Array($0)) }
        valid = phrase.utf8.count <= 512 && tokens.count <= 8
    }

    var isEmpty: Bool { phrase.isEmpty }
    var tokenTexts: [String] { tokens.map(\.text) }

    /// `key` must come from `FileSearchKey.make`. Returns nil when the name does not match.
    func rank(_ key: String) -> UInt8? {
        guard valid else { return nil }
        if key == phrase { return 0 }
        if key.hasPrefix(phrase) { return 1 }
        if key.contains(phrase) { return 2 }
        if tokens.allSatisfy({ key.contains($0.text) }) { return 3 }
        let fuzzy = tokens.allSatisfy { token in
            if key.contains(token.text) { return true }
            // Very short fuzzy tokens and unbounded gaps would match most filenames.
            let count = token.characters.count
            guard (3...64).contains(count) else { return false }
            var matched = 0
            var span = 0
            for character in key.prefix(1024) {
                if matched > 0 { span += 1 }
                if span > count * 3 { return false }
                if token.characters[matched] == character {
                    matched += 1
                    if matched == count { return true }
                }
            }
            return false
        }
        return fuzzy ? 4 : nil
    }
}

/// The Files screen's type filter, matching the Tauri `fileType` values.
enum FileTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all, folder, text, image, document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All Files", bundle: .module)
        case .folder: String(localized: "Folders", bundle: .module)
        case .text: String(localized: "Text", bundle: .module)
        case .image: String(localized: "Images", bundle: .module)
        case .document: String(localized: "Documents", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .all: "doc.on.doc"
        case .folder: "folder"
        case .text: "doc.plaintext"
        case .image: "photo"
        case .document: "doc.richtext"
        }
    }

    func matches(name: String, isDirectory: Bool) -> Bool {
        if self == .all { return true }
        if isDirectory { return self == .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        return switch self {
        case .text: Self.textExtensions.contains(ext)
        case .image: Self.imageExtensions.contains(ext)
        case .document: Self.documentExtensions.contains(ext)
        case .all, .folder: false
        }
    }

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "ini",
        "log", "rs", "js", "jsx", "ts", "tsx", "py", "swift", "kt", "java", "css", "html", "xml", "sh", "sql",
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg"]
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "rtf",
    ]
}

/// One file or folder result, from Spotlight or the folder index.
struct FileHit: Sendable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let isDirectory: Bool
    /// Spotlight's last-used date. Breaks ties within a rank so recently used files come first.
    var lastUsed: Date?

    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory) }

    /// The parent folder with the home folder shortened to `~`, shown as the row subtitle.
    var displayLocation: String { Self.abbreviate((path as NSString).deletingLastPathComponent) }

    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

enum FileRanking {
    /// Merges local and Spotlight hits by path (local wins), keeps matches for `filter`, and sorts by rank,
    /// then recency, then normalized name and path so pages are deterministic.
    static func merge(_ sources: [[FileHit]], query: FilenameQuery, filter: FileTypeFilter, limit: Int) -> (hits: [FileHit], total: Int) {
        var seen = Set<String>()
        var ranked: [(hit: FileHit, rank: UInt8, key: String)] = []
        for source in sources {
            for hit in source where seen.insert(hit.path).inserted {
                let key = FileSearchKey.make(hit.name)
                guard filter.matches(name: hit.name, isDirectory: hit.isDirectory), let rank = query.rank(key) else { continue }
                ranked.append((hit, rank, key))
            }
        }
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            let aUsed = a.hit.lastUsed ?? .distantPast, bUsed = b.hit.lastUsed ?? .distantPast
            if aUsed != bUsed { return aUsed > bUsed }
            if a.key != b.key { return a.key < b.key }
            return a.hit.path < b.hit.path
        }
        return (ranked.prefix(limit).map(\.hit), ranked.count)
    }
}
