import Foundation

/// One release announced by `latest.json`, resolved for this Mac.
struct UpdateRelease: Equatable, Sendable {
    let version: SemanticVersion
    let url: URL
    /// The Tauri-format signature: minisign signature text wrapped in base64.
    let signature: String
    let notes: String?
}

/// The Tauri updater feed, `https://github.com/kmelon55/Prism/releases/latest/download/latest.json`:
///
///     { "version": "0.1.19", "notes": "…", "pub_date": "…",
///       "platforms": { "darwin-aarch64": { "signature": "…", "url": "…" }, "darwin-x86_64": { … } } }
///
/// Tauri also accepts a single-platform form with `url` and `signature` at the top level, so this does too.
enum UpdateFeed {
    static let url = URL(string: "https://github.com/kmelon55/Prism/releases/latest/download/latest.json")!

    enum Failure: Error, Equatable {
        case invalidFeed
        case missingPlatform(String)
    }

    /// The feed key for this Mac. Tauri looks up `darwin-aarch64-app` before `darwin-aarch64`.
    static var target: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }

    private struct Platform: Decodable {
        let url: String
        let signature: String
    }

    private struct Document: Decodable {
        let version: String
        let notes: String?
        let url: String?
        let signature: String?
        let platforms: [String: Platform]?
    }

    static func release(from data: Data, target: String = target) throws(Failure) -> UpdateRelease {
        let (document, version) = try parse(data)
        return try resolve(document, version: version, target: target)
    }

    /// An update exists only when the feed's version is strictly newer, as in Tauri's default comparator.
    /// Like Tauri, a feed that is not newer is not required to list this Mac's platform.
    static func update(in data: Data, currentVersion: SemanticVersion, target: String = target) throws(Failure) -> UpdateRelease? {
        let (document, version) = try parse(data)
        guard version > currentVersion else { return nil }
        return try resolve(document, version: version, target: target)
    }

    private static func parse(_ data: Data) throws(Failure) -> (Document, SemanticVersion) {
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              let version = SemanticVersion(document.version)
        else { throw .invalidFeed }
        return (document, version)
    }

    private static func resolve(_ document: Document, version: SemanticVersion, target: String) throws(Failure) -> UpdateRelease {
        let platform: Platform
        if let platforms = document.platforms {
            guard let match = platforms["\(target)-app"] ?? platforms[target] else { throw .missingPlatform(target) }
            platform = match
        } else if let url = document.url, let signature = document.signature {
            platform = Platform(url: url, signature: signature)
        } else {
            throw .invalidFeed
        }
        // Updates are only fetched over HTTPS.
        guard let url = URL(string: platform.url), url.scheme?.lowercased() == "https", url.host() != nil,
              !platform.signature.isEmpty
        else { throw .invalidFeed }
        return UpdateRelease(version: version, url: url, signature: platform.signature, notes: document.notes)
    }
}
