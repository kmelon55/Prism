import Foundation
import PrismKit
import Security

/// Generic-password access with an explicit prompt policy. Settings and ordinary requests read silently and reuse
/// existing authorization; only deliberate actions ("Allow key use") may show the macOS dialog.
struct AIKeychain: Sendable {
    let service: String

    /// The release app shares the Tauri services so saved keys carry over. Development builds use their own
    /// services, like `AppPaths`, so they never touch the installed app's keys.
    static var providerService: String { AppPaths.keychainService("ai") }
    static var compatibleService: String { AppPaths.keychainService("ai.compatible") }

    /// Serializes every Prism keychain operation so a silent read cannot suppress an explicit save elsewhere.
    private static let operations = NSLock()

    func read(account: String, allowPrompt: Bool) throws -> Data? {
        Self.operations.lock(); defer { Self.operations.unlock() }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowPrompt {
            // kSecUseAuthenticationUI / kSecUseAuthenticationUIFail, spelled out to avoid the deprecated constants.
            query["u_AuthUI"] = "u_AuthUIF"
        }
        var result: CFTypeRef?
        let status = Self.withInteraction(allowed: allowPrompt) { SecItemCopyMatching(query as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AIError(Self.readError(status, allowPrompt: allowPrompt)) }
        return result as? Data
    }

    /// Metadata only: never reads password data and never prompts.
    func exists(account: String) throws -> Bool {
        Self.operations.lock(); defer { Self.operations.unlock() }
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query["u_AuthUI"] = "u_AuthUISkip"
        let status = Self.withInteraction(allowed: false) { SecItemCopyMatching(query as CFDictionary, nil) }
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed: return true
        case errSecItemNotFound: return false
        default: throw AIError(L("Could not verify key storage. Check whether Keychain is locked."))
        }
    }

    func save(_ data: Data, account: String) throws {
        Self.operations.lock(); defer { Self.operations.unlock() }
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AIError(L("Could not save the API key in Keychain.")) }
        } else if status != errSecSuccess {
            throw AIError(L("Could not save the API key in Keychain."))
        }
    }

    func delete(account: String) throws {
        Self.operations.lock(); defer { Self.operations.unlock() }
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError(L("Could not delete the API key.")) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func readError(_ status: OSStatus, allowPrompt: Bool) -> String {
        switch status {
        case -128: L("Keychain authorization was canceled. Try the action again when ready.")
        case -25293 where !allowPrompt, -25308 where !allowPrompt: L("Keychain authorization is required.")
        case -25293: L("Keychain access was denied. Try again and approve access in the macOS dialog.")
        case -25308: L("macOS could not show the Keychain authorization dialog. Unlock your session and try again.")
        default: L("Could not read the saved key (macOS error \(Int(status))).")
        }
    }

    /// The file-based login keychain does not always honor the per-query UI policy, so silent reads also turn off
    /// legacy keychain interaction for their duration, as the Tauri host does.
    private static func withInteraction(allowed: Bool, _ body: () -> OSStatus) -> OSStatus {
        guard !allowed, let get = legacyGet, let set = legacySet else { return body() }
        var previous: DarwinBoolean = true
        guard get(&previous) == errSecSuccess, set(false) == errSecSuccess else { return body() }
        defer { _ = set(previous) }
        return body()
    }

    private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    private typealias SetInteraction = @convention(c) (DarwinBoolean) -> OSStatus
    private static let legacyGet: GetInteraction? = symbol("SecKeychainGetUserInteractionAllowed")
    private static let legacySet: SetInteraction? = symbol("SecKeychainSetUserInteractionAllowed")

    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// One provider's authorized key, kept in process memory only. Repeated reads share one authorization, and a
/// canceled macOS dialog is not reopened by callers queued behind it.
struct KeySession: Sendable {
    private(set) var key: Data?
    private var denied: (date: Date, error: AIError)?

    func peek() -> Data? { key }

    mutating func replace(_ key: Data) {
        self.key = key
        denied = nil
    }

    mutating func clear() {
        key = nil
        denied = nil
    }

    mutating func allowRetry() { denied = nil }

    /// Restores previously authorized access without recording a denial, so a settings probe never suppresses the
    /// next deliberate request.
    mutating func loadSilent(_ read: () throws -> Data?) throws -> Data? {
        if let key { return key }
        if let value = try read() { replace(value) }
        return key
    }

    mutating func load(_ read: () throws -> Data?, now: Date = Date()) throws -> Data? {
        if let key { return key }
        if let denied, now.timeIntervalSince(denied.date) < 5 { throw denied.error }
        do {
            if let value = try read() {
                replace(value)
                return value
            }
            clear()
            return nil
        } catch {
            let failure = error as? AIError ?? AIError(error.localizedDescription)
            denied = (now, failure)
            throw failure
        }
    }
}

/// What settings may show about a saved key: never the key itself.
public struct AIKeyInfo: Equatable, Sendable {
    public var configured: Bool
    public var maskedKey: String?
    public var unlocked: Bool

    static func from(_ key: Data?) -> AIKeyInfo {
        guard let key else { return AIKeyInfo(configured: false, maskedKey: nil, unlocked: false) }
        let suffix = key.count >= 12 ? String(data: key.suffix(4), encoding: .utf8) ?? "" : ""
        return AIKeyInfo(configured: true, maskedKey: "•••• •••• \(suffix)".trimmingCharacters(in: .whitespaces), unlocked: true)
    }
}

/// API keys for the fixed providers (`dev.prism.desktop.ai`, account = provider) and the single custom server
/// (`dev.prism.desktop.ai.compatible`, account = normalized base URL).
final class AIKeyStore: @unchecked Sendable {
    let keychain: AIKeychain
    let compatibleKeychain: AIKeychain
    private let lock = NSLock()
    private var sessions: [AIProvider: KeySession] = [:]
    private var compatibleSession: (base: String, session: KeySession)?

    init(service: String = AIKeychain.providerService, compatibleService: String = AIKeychain.compatibleService) {
        keychain = AIKeychain(service: service)
        compatibleKeychain = AIKeychain(service: compatibleService)
    }

    func info(_ provider: AIProvider) throws -> AIKeyInfo {
        lock.lock(); defer { lock.unlock() }
        var session = sessions[provider] ?? KeySession()
        defer { sessions[provider] = session }
        if let key = session.peek() { return .from(key) }
        if let key = try? session.loadSilent({ try keychain.read(account: provider.account, allowPrompt: false) }) {
            return .from(key)
        }
        return AIKeyInfo(configured: try keychain.exists(account: provider.account), maskedKey: nil, unlocked: false)
    }

    /// An explicit "Allow key use" action. May show the macOS authorization dialog.
    func unlock(_ provider: AIProvider) throws -> AIKeyInfo {
        lock.lock(); defer { lock.unlock() }
        var session = sessions[provider] ?? KeySession()
        session.allowRetry()
        defer { sessions[provider] = session }
        return .from(try session.load { try keychain.read(account: provider.account, allowPrompt: true) })
    }

    /// The key for a deliberate feature request. Reuses authorization; never opens a dialog by itself.
    func key(for provider: AIProvider) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        var session = sessions[provider] ?? KeySession()
        defer { sessions[provider] = session }
        return try session.load { try keychain.read(account: provider.account, allowPrompt: false) }
    }

    /// Only a key already opened in this process. OpenAI catalog loading uses this so it can never prompt.
    func cachedKey(for provider: AIProvider) throws -> Data {
        guard lock.try() else { throw AIError(L("Key authorization is in progress. Try again shortly.")) }
        defer { lock.unlock() }
        guard let key = sessions[provider]?.peek() else { throw AIError(L("Allow key use in AI settings to load models.")) }
        return key
    }

    func save(_ provider: AIProvider, key: String) throws -> AIKeyInfo {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, AIRequest.isASCIIGraphic(key) else {
            throw AIError(L("Enter an API key without spaces or line breaks."))
        }
        lock.lock(); defer { lock.unlock() }
        let data = Data(key.utf8)
        try keychain.save(data, account: provider.account)
        // A successful write is the acknowledgement. Reading back could show a second dialog.
        var session = sessions[provider] ?? KeySession()
        session.replace(data)
        sessions[provider] = session
        return .from(data)
    }

    func delete(_ provider: AIProvider) throws {
        lock.lock(); defer { lock.unlock() }
        try keychain.delete(account: provider.account)
        sessions[provider] = nil
    }

    // MARK: Custom server

    func compatibleKey(base: String, allowPrompt: Bool) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if compatibleSession?.base != base { compatibleSession = (base, KeySession()) }
        var session = compatibleSession!.session
        defer { compatibleSession = (base, session) }
        let read = { try self.compatibleKeychain.read(account: base, allowPrompt: allowPrompt) }
        return allowPrompt ? try session.load(read) : try session.loadSilent(read)
    }

    func saveCompatibleKey(_ key: String?, base: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let key {
            var session = KeySession()
            if !key.isEmpty {
                try compatibleKeychain.save(Data(key.utf8), account: base)
                session.replace(Data(key.utf8))
            }
            compatibleSession = (base, session)
        } else if compatibleSession?.base != base {
            compatibleSession = nil
        }
    }
}
