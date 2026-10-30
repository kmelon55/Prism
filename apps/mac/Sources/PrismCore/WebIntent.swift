import Foundation

/// The Tauri rules from `web.ts` and `web.rs`: only explicit addresses with a host and no credentials, and searches
/// encoded into a fixed HTTPS address.
public enum WebIntent: Equatable, Sendable {
    case url(URL)
    case search(String)

    public static let maximumURLBytes = 2_048
    public static let maximumQueryBytes = 1_024
    public static let searchPrefix = "web "

    public init?(_ value: String) {
        guard !value.isEmpty, !Self.hasControlCharacter(value), value.utf8.count <= Self.maximumURLBytes else { return nil }
        let lowered = value.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = Self.validatedURL(value) else { return nil }
            self = .url(url)
        } else if lowered.hasPrefix(Self.searchPrefix) {
            let terms = value.dropFirst(Self.searchPrefix.count).trimmingCharacters(in: .whitespaces)
            guard !terms.isEmpty else { return nil }
            self = .search(terms)
        } else {
            return nil
        }
    }

    public static func validatedURL(_ value: String) -> URL? {
        guard !value.contains(where: \.isWhitespace), !value.contains("\\"),
              let range = value.range(of: "://") else { return nil }
        let afterScheme = value[range.upperBound...]
        let authority = afterScheme.prefix { !"/?#".contains($0) }
        guard !authority.isEmpty, !authority.contains("@"),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url, url.absoluteString.utf8.count <= maximumURLBytes else { return nil }
        return url
    }

    public static func searchURL(_ terms: String) -> URL? {
        guard terms.utf8.count <= maximumQueryBytes, !hasControlCharacter(terms) else { return nil }
        guard var components = URLComponents(string: "https://www.google.com/search") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: terms)]
        // `+` is literal in a query item; encode it so it is not read as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url
    }

    private static func hasControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
