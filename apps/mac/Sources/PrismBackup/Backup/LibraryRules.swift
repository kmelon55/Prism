import Foundation

/// The library's record rules from `library.rs` (`valid_id`, `validate_entry`, `validate_link_template`), so a
/// backup is checked exactly as the library would check each record before anything is written.
enum LibraryRules {
    static let maxEntries = 1000
    static let maxTotalBytes = 16 * 1024 * 1024
    static let maxEntryBytes = 128 * 1024
    static let maxTitleBytes = 300
    static let maxFavorites = 50
    static let maxURLBytes = 2048

    struct Invalid: Error {}

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func normalizedKeyword(_ keyword: String?) -> String? {
        guard let keyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !keyword.isEmpty else { return nil }
        return keyword
    }

    /// `; ! / :` followed by 1–47 ASCII letters, digits or `_ - ; ! / :`.
    static func isValidKeyword(_ keyword: String) -> Bool {
        let bytes = Array(keyword.utf8)
        guard (2...48).contains(bytes.count), let first = bytes.first, Set(";!/:".utf8).contains(first) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || Set("_-;!/:".utf8).contains(byte)
        }
    }

    static func validate(_ entry: BackupEntry) throws {
        guard isValidID(entry.id), !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.title.utf8.count <= maxTitleBytes, !entry.value.isEmpty || entry.kind == "note",
              entry.value.utf8.count <= maxEntryBytes
        else { throw Invalid() }
        if let keyword = normalizedKeyword(entry.keyword) {
            guard entry.kind == "snippet", isValidKeyword(keyword) else { throw Invalid() }
        }
        switch entry.kind {
        case "snippet", "note": break
        case "link": try validateLinkTemplate(entry.value)
        case "path":
            guard entry.value.hasPrefix("/"), !entry.value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw Invalid() }
        default: throw Invalid()
        }
    }

    /// `{query}` may appear only in the URL query, never in the scheme, host, path or fragment.
    static func validateLinkTemplate(_ value: String) throws {
        if value.contains("{query}") {
            guard let questionMark = value.firstIndex(of: "?") else { throw Invalid() }
            let query = value[value.index(after: questionMark)...]
            if value[..<questionMark].contains("{query}") { throw Invalid() }
            if let hash = query.firstIndex(of: "#"), query[query.index(after: hash)...].contains("{query}") { throw Invalid() }
        }
        try validateHTTPURL(value.replacingOccurrences(of: "{query}", with: "prism"))
    }

    /// `web::validated_http_url`: HTTP(S) only, with a host and without credentials, whitespace or backslashes.
    static func validateHTTPURL(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= maxURLBytes,
              !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }),
              !value.contains("\\"), let schemeRange = value.range(of: "://")
        else { throw Invalid() }
        let authority = value[schemeRange.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.isEmpty, !authority.contains("@"), let components = URLComponents(string: value), components.url != nil,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              value.lowercased().hasPrefix(scheme + "://"), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { throw Invalid() }
    }
}
