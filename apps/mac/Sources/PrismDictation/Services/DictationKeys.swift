import Foundation
import PrismKit

/// Keychain access behind a protocol so tests use their own service names.
protocol DictationKeyStorage: Sendable {
    func read(service: String, account: String) throws -> Data?
    func exists(service: String, account: String) -> Bool
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

struct SystemKeyStorage: DictationKeyStorage {
    func read(service: String, account: String) throws -> Data? { try Keychain.read(service: service, account: account) }
    func exists(service: String, account: String) -> Bool { Keychain.exists(service: service, account: account) }
    func save(_ data: Data, service: String, account: String) throws { try Keychain.save(data, service: service, account: account) }
    func delete(service: String, account: String) throws { try Keychain.delete(service: service, account: account) }
}

struct DictationKeyInfo: Equatable, Sendable {
    var configured: Bool
    /// `•••• •••• abcd`, only after the key was read in this session. Short keys never show a suffix.
    var maskedKey: String?

    static func masked(_ key: String) -> String {
        let suffix = key.utf8.count >= 12 ? String(key.suffix(4)) : ""
        return "•••• •••• \(suffix)".trimmingCharacters(in: .whitespaces)
    }
}

/// API keys for speech and text providers. Service and account names match the Tauri app, so saved keys carry
/// over: OpenAI and Vercel share AI chat's accounts; Groq, xAI and custom servers have dictation accounts.
/// Like `AppPaths`, development builds use their own services so they never change the installed app's keys.
final class DictationKeys: @unchecked Sendable {
    static let releaseService = "dev.prism.desktop.ai"
    static let releaseCompatibleService = "dev.prism.desktop.ai.compatible"
    static var service: String { AppPaths.keychainService("ai") }
    static var compatibleService: String { AppPaths.keychainService("ai.compatible") }

    let service: String
    let compatibleService: String
    private let storage: any DictationKeyStorage
    private let lock = NSLock()
    /// Keys read during this process, so one approval covers the session.
    private var cache: [String: String] = [:]

    init(service: String = DictationKeys.service, compatibleService: String = DictationKeys.compatibleService,
         storage: any DictationKeyStorage = SystemKeyStorage()) {
        self.service = service
        self.compatibleService = compatibleService
        self.storage = storage
    }

    static func account(for provider: SpeechProvider) -> String? {
        switch provider {
        case .openai: "openai"
        case .vercel: "vercel"
        case .groq: "dictation-groq"
        case .xai: "dictation-xai"
        case .custom: "dictation-custom"
        case .local: nil
        }
    }

    /// Whether the account is shared with AI chat, so deleting it affects chat too.
    static func isShared(_ provider: SpeechProvider) -> Bool { provider == .openai || provider == .vercel }

    /// Checks for a stored key without reading its bytes, so no Keychain prompt appears.
    func info(for provider: SpeechProvider) -> DictationKeyInfo {
        guard let account = Self.account(for: provider) else { return DictationKeyInfo(configured: false) }
        if let key = cached(account) { return DictationKeyInfo(configured: true, maskedKey: DictationKeyInfo.masked(key)) }
        return DictationKeyInfo(configured: storage.exists(service: service, account: account))
    }

    func save(_ key: String, for provider: SpeechProvider) throws -> DictationKeyInfo {
        guard let account = Self.account(for: provider) else { throw DictationError(String(localized: "This provider does not use an API key.", bundle: .module)) }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
            throw DictationError(String(localized: "Enter an API key without spaces or line breaks.", bundle: .module))
        }
        do { try storage.save(Data(key.utf8), service: service, account: account) } catch {
            throw DictationError(String(localized: "Could not save the API key.", bundle: .module))
        }
        store(key, for: account)
        return DictationKeyInfo(configured: true, maskedKey: DictationKeyInfo.masked(key))
    }

    func delete(for provider: SpeechProvider) throws {
        guard let account = Self.account(for: provider) else { return }
        do { try storage.delete(service: service, account: account) } catch {
            throw DictationError(String(localized: "Could not delete the key.", bundle: .module))
        }
        store(nil, for: account)
    }

    /// Reads the key for a recording or catalog request. May show the macOS Keychain dialog once.
    func key(for provider: SpeechProvider) throws -> String {
        guard let account = Self.account(for: provider) else { return "" }
        return try readKey(service: service, account: account)
    }

    /// The key for a text-processing provider, or nil when a custom server needs none.
    func key(for provider: TextProvider, compatibleBase: String?) throws -> String? {
        switch provider {
        case .openai, .openrouter, .vercel:
            return try readKey(service: service, account: provider.rawValue)
        case .compatible:
            guard let compatibleBase else { return nil }
            return try readKey(service: compatibleService, account: compatibleBase)
        }
    }

    private func readKey(service: String, account: String) throws -> String {
        if service == self.service, let key = cached(account) { return key }
        let data: Data?
        do { data = try storage.read(service: service, account: account) } catch {
            throw DictationError(String(localized: "Keychain access was denied. Try again and approve access in the macOS dialog.", bundle: .module))
        }
        guard let data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw DictationError(String(localized: "Save an API key in dictation settings.", bundle: .module))
        }
        if service == self.service { store(key, for: account) }
        return key
    }

    private func cached(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[account]
    }

    private func store(_ key: String?, for account: String) {
        lock.lock(); defer { lock.unlock() }
        cache[account] = key
    }
}

/// The custom AI server saved in AI settings (`ai-compatible-v1.json`). Its key lives under the base URL.
struct CompatibleConnection: Decodable, Sendable {
    var baseUrl: String
    var hasKey: Bool

    static func load(paths: AppPaths) -> CompatibleConnection? {
        guard let data = try? Data(contentsOf: paths.dataDirectory.appending(path: "ai-compatible-v1.json")),
              let connection = try? JSONDecoder().decode(CompatibleConnection.self, from: data) else { return nil }
        return connection
    }

    /// The Tauri app's normalized base: the URL with a single trailing slash.
    var normalizedBase: String? {
        let raw = baseUrl.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: raw), let scheme = components.scheme, ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.path = components.path.trimmingTrailing("/") + "/"
        return components.string
    }
}
