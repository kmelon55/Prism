import Foundation

/// One saved library record. Matches the Tauri `Entry` and the `entries` table of `library-v1.sqlite3`.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case link, path, snippet, note
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var value: String
    public var keyword: String?

    public init(id: String = LibraryEntry.newID(), kind: Kind, title: String, value: String, keyword: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.value = value
        self.keyword = keyword
    }

    /// Lowercase UUIDs, like `crypto.randomUUID()` in the Tauri app.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// The palette row ID, which favorites and command shortcuts refer to.
    public var paletteID: String { "library:\(id)" }

    var isQuicklink: Bool { kind == .link || kind == .path }

    /// The trimmed keyword, or nil when it is empty.
    var normalizedKeyword: String? {
        guard let keyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !keyword.isEmpty else { return nil }
        return keyword
    }

    /// Links with `{query}` and snippets with date, time or clipboard placeholders show a preview before they run.
    var isDynamic: Bool {
        switch kind {
        case .link: value.contains("{query}")
        case .snippet: LibraryTemplate.snippetPlaceholders.contains { value.contains($0) }
        case .path, .note: false
        }
    }

    var needsQuery: Bool { kind == .link && value.contains("{query}") }
}

/// Limits from `library.rs` and `docs/local-library.md`.
enum LibraryLimits {
    static let maxEntries = 1000
    static let maxTotalBytes = 16 * 1024 * 1024
    static let maxEntryBytes = 128 * 1024
    static let maxTitleBytes = 300
    static let maxFavorites = 50
    static let maxFavoriteTitleBytes = 500
    static let maxURLBytes = 2048
    static let maxQueryBytes = 8192
}

enum LibraryError: LocalizedError, Equatable {
    case invalidEntry
    case invalidKeyword
    case duplicateKeyword
    case invalidPath
    case unsupportedKind
    case full
    case queryOutsideURLQuery
    case invalidURL(String)
    case emptyQuery
    case expandedTooLong
    case clipboardEmpty
    case clipboardTooLong
    case entryDeleted
    case entryChanged
    case invalidFavorite
    case tooManyFavorites
    case favoritesChanged
    case storage
    case pathMissing

    var errorDescription: String? {
        switch self {
        case .invalidEntry: L10n.tr("Check the name and content. Content can be up to 128 KB.")
        case .invalidKeyword: L10n.tr("Use 2–48 characters, starting with ; ! / or : and containing letters, numbers, _ - ; ! / :.")
        case .duplicateKeyword: L10n.tr("This snippet keyword is already in use.")
        case .invalidPath: L10n.tr("Choose an absolute path.")
        case .unsupportedKind: L10n.tr("This library entry is not supported.")
        case .full: L10n.tr("The library is full. Delete entries you no longer need.")
        case .queryOutsideURLQuery: L10n.tr("Query placeholders can only appear in the URL query.")
        case .invalidURL(let message): message
        case .emptyQuery: L10n.tr("Enter a search term.")
        case .expandedTooLong: L10n.tr("Expanded content must be at most 128 KB.")
        case .clipboardEmpty: L10n.tr("The clipboard does not contain text.")
        case .clipboardTooLong: L10n.tr("The clipboard text is too long.")
        case .entryDeleted: L10n.tr("The entry was deleted.")
        case .entryChanged: L10n.tr("The entry changed. Load the preview again.")
        case .invalidFavorite: L10n.tr("This favorite is not valid.")
        case .tooManyFavorites: L10n.tr("You can have up to 50 favorites.")
        case .favoritesChanged: L10n.tr("Favorites changed. Try again.")
        case .storage: L10n.tr("Could not complete the action.")
        case .pathMissing: L10n.tr("The file was moved or deleted.")
        }
    }
}

enum LibraryValidation {
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// `; ! / :` followed by 1–47 ASCII letters, digits or `_ - ; ! / :`. Case sensitive.
    static func isValidKeyword(_ keyword: String) -> Bool {
        let bytes = Array(keyword.utf8)
        guard (2...48).contains(bytes.count), let first = bytes.first, Self.keywordPrefixes.contains(first) else { return false }
        return bytes.allSatisfy { $0 < 128 && (isASCIIAlphanumeric($0) || Self.keywordPunctuation.contains($0)) }
    }

    /// The editor accepts an empty keyword, which turns expansion off for that snippet.
    static func isValidOptionalKeyword(_ keyword: String?) -> Bool {
        guard let keyword, !keyword.isEmpty else { return true }
        return isValidKeyword(keyword)
    }

    static let keywordPrefixes: Set<UInt8> = [UInt8(ascii: ";"), UInt8(ascii: "!"), UInt8(ascii: "/"), UInt8(ascii: ":")]
    static let keywordPunctuation: Set<UInt8> = Set("_-;!/:".utf8)

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    static func validate(_ entry: LibraryEntry) throws {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidID(entry.id), !title.isEmpty, entry.title.utf8.count <= LibraryLimits.maxTitleBytes,
              !entry.value.isEmpty || entry.kind == .note, entry.value.utf8.count <= LibraryLimits.maxEntryBytes
        else { throw LibraryError.invalidEntry }
        if let keyword = entry.normalizedKeyword {
            guard entry.kind == .snippet, isValidKeyword(keyword) else { throw LibraryError.invalidKeyword }
        }
        switch entry.kind {
        case .snippet, .note: break
        case .link: try LibraryTemplate.validateLinkTemplate(entry.value)
        case .path:
            guard entry.value.hasPrefix("/"), !entry.value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw LibraryError.invalidPath }
        }
    }

    /// A port of `web::validated_http_url`: HTTP(S) only, with a host and without credentials or whitespace.
    @discardableResult
    static func validatedHTTPURL(_ value: String) throws -> URL {
        if value.isEmpty { throw LibraryError.invalidURL(L10n.tr("Enter a web URL to open.")) }
        if value.utf8.count > LibraryLimits.maxURLBytes { throw LibraryError.invalidURL(L10n.tr("The web URL is too long.")) }
        if value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) {
            throw LibraryError.invalidURL(L10n.tr("The web URL contains unsupported whitespace or control characters."))
        }
        if value.contains("\\") { throw LibraryError.invalidURL(L10n.tr("The web URL contains an unsupported backslash.")) }
        guard let schemeRange = value.range(of: "://") else {
            throw LibraryError.invalidURL(L10n.tr("The web URL must start with http:// or https://."))
        }
        let afterScheme = value[schemeRange.upperBound...]
        let authority = afterScheme.prefix { !"/?#".contains($0) }
        if authority.isEmpty { throw LibraryError.invalidURL(L10n.tr("The web URL must include a host.")) }
        guard let components = URLComponents(string: value), let url = components.url else {
            throw LibraryError.invalidURL(L10n.tr("The web URL is not valid."))
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              value.lowercased().hasPrefix(scheme + "://")
        else { throw LibraryError.invalidURL(L10n.tr("Prism opens only HTTP and HTTPS web URLs.")) }
        guard let host = components.host, !host.isEmpty else { throw LibraryError.invalidURL(L10n.tr("The web URL must include a host.")) }
        if authority.contains("@") || components.user != nil || components.password != nil {
            throw LibraryError.invalidURL(L10n.tr("Prism does not open web URLs containing credentials."))
        }
        return url
    }
}

/// Placeholder expansion, ported from `expand_entry` in `library.rs`.
enum LibraryTemplate {
    static let snippetPlaceholders = ["{date}", "{time}", "{clipboard}"]

    /// `{query}` may appear only in the URL query, never in the scheme, host, path or fragment.
    static func validateLinkTemplate(_ value: String) throws {
        if value.contains("{query}") {
            guard let questionMark = value.firstIndex(of: "?") else { throw LibraryError.queryOutsideURLQuery }
            let beforeQuery = value[..<questionMark]
            let query = value[value.index(after: questionMark)...]
            if beforeQuery.contains("{query}") { throw LibraryError.queryOutsideURLQuery }
            if let hash = query.firstIndex(of: "#"), query[query.index(after: hash)...].contains("{query}") {
                throw LibraryError.queryOutsideURLQuery
            }
        }
        try LibraryValidation.validatedHTTPURL(value.replacingOccurrences(of: "{query}", with: "prism"))
    }

    /// Percent-encodes every UTF-8 byte except unreserved ASCII.
    static func encodeQuery(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "-._~".utf8.contains(byte) {
                encoded.append(Character(Unicode.Scalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func expand(_ entry: LibraryEntry, query: String?, date: String, time: String, clipboard: String) throws -> String {
        if entry.kind == .link && entry.value.contains("{query}") {
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf8.count <= LibraryLimits.maxQueryBytes
            else { throw LibraryError.emptyQuery }
            let value = entry.value.replacingOccurrences(of: "{query}", with: encodeQuery(query))
            try LibraryValidation.validatedHTTPURL(value)
            return value
        }
        guard entry.kind == .snippet else { return entry.value }
        // A single pass, so clipboard text is never read as a template.
        var result = ""
        var rest = Substring(entry.value)
        let replacements = [("{date}", date), ("{time}", time), ("{clipboard}", clipboard)]
        while let brace = rest.firstIndex(of: "{") {
            result += rest[..<brace]
            rest = rest[brace...]
            if let (token, value) = replacements.first(where: { rest.hasPrefix($0.0) }) {
                result += value
                rest = rest.dropFirst(token.count)
            } else {
                result += "{"
                rest = rest.dropFirst()
            }
            if result.utf8.count > LibraryLimits.maxEntryBytes { throw LibraryError.expandedTooLong }
        }
        result += rest
        if result.utf8.count > LibraryLimits.maxEntryBytes { throw LibraryError.expandedTooLong }
        return result
    }

    /// Local `YYYY-MM-DD` and `HH:mm`.
    static func localDateTime(_ date: Date = Date()) -> (date: String, time: String) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (
            String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0),
            String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        )
    }
}
