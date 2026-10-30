import Foundation
import PrismKit
import Testing
@testable import PrismDictation

/// In-memory Keychain stand-in. Real Keychain access below uses a test-only service.
final class MemoryKeyStorage: DictationKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var reads = 0

    func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return items["\(service)/\(account)"]
    }

    func exists(service: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items["\(service)/\(account)"] != nil
    }

    func save(_ data: Data, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items["\(service)/\(account)"] = data
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items["\(service)/\(account)"] = nil
    }
}

struct KeysTests {
    @Test func accountsMatchTheTauriApp() {
        #expect(DictationKeys.releaseService == "dev.prism.desktop.ai")
        #expect(DictationKeys.releaseCompatibleService == "dev.prism.desktop.ai.compatible")
        #expect(DictationKeys.service == "dev.prism.native-dev.ai", "Test and development builds never touch the installed app's keys")
        #expect(DictationKeys.account(for: .openai) == "openai")
        #expect(DictationKeys.account(for: .vercel) == "vercel")
        #expect(DictationKeys.account(for: .groq) == "dictation-groq")
        #expect(DictationKeys.account(for: .xai) == "dictation-xai")
        #expect(DictationKeys.account(for: .custom) == "dictation-custom")
        #expect(DictationKeys.account(for: .local) == nil)
        #expect(DictationKeys.isShared(.openai) && !DictationKeys.isShared(.groq))
    }

    @Test func savesMasksAndDeletesWithoutExposingShortKeys() throws {
        let storage = MemoryKeyStorage()
        let keys = DictationKeys(service: "dev.prism.native-tests.dictation", storage: storage)
        #expect(!keys.info(for: .groq).configured)
        #expect(throws: DictationError.self) { try keys.save("has space", for: .groq) }
        #expect(throws: DictationError.self) { try keys.save("   ", for: .groq) }
        #expect(try keys.save("  gsk-fixture-123456  ", for: .groq).maskedKey == "•••• •••• 3456")
        #expect(try keys.key(for: .groq) == "gsk-fixture-123456")
        #expect(storage.reads == 0, "A saved key is cached for the session")
        #expect(DictationKeyInfo.masked("short") == "•••• ••••")
        try keys.delete(for: .groq)
        #expect(!keys.info(for: .groq).configured)
        #expect(throws: DictationError.self) { try keys.key(for: .groq) }
    }

    @Test func statusDoesNotReadKeyBytes() throws {
        let storage = MemoryKeyStorage()
        try storage.save(Data("sk-fixture-abcdefgh".utf8), service: "dev.prism.native-tests.dictation", account: "openai")
        let keys = DictationKeys(service: "dev.prism.native-tests.dictation", storage: storage)
        let info = keys.info(for: .openai)
        #expect(info.configured && info.maskedKey == nil && storage.reads == 0)
    }

    @Test func textProvidersUseAIAccountsAndCompatibleBase() throws {
        let storage = MemoryKeyStorage()
        let keys = DictationKeys(service: "test.ai", compatibleService: "test.ai.compatible", storage: storage)
        try storage.save(Data("or-key".utf8), service: "test.ai", account: "openrouter")
        try storage.save(Data("local-key".utf8), service: "test.ai.compatible", account: "http://localhost:11434/v1/")
        #expect(try keys.key(for: .openrouter, compatibleBase: nil) == "or-key")
        #expect(try keys.key(for: .compatible, compatibleBase: "http://localhost:11434/v1/") == "local-key")
        #expect(try keys.key(for: .compatible, compatibleBase: nil) == nil)
    }

    @Test func compatibleBaseIsNormalizedLikeAISettings() {
        #expect(CompatibleConnection(baseUrl: "http://localhost:11434/v1", hasKey: true).normalizedBase == "http://localhost:11434/v1/")
        #expect(CompatibleConnection(baseUrl: "https://x.test/v1///", hasKey: false).normalizedBase == "https://x.test/v1/")
        #expect(CompatibleConnection(baseUrl: "https://u:p@x.test/v1", hasKey: false).normalizedBase == nil)
    }

    @Test func realKeychainRoundTripWithTestService() throws {
        let service = "dev.prism.native-tests.dictation.\(UUID().uuidString)"
        let keys = DictationKeys(service: service)
        defer { try? Keychain.delete(service: service, account: "dictation-xai") }
        _ = try keys.save("xai-fixture-roundtrip", for: .xai)
        #expect(Keychain.exists(service: service, account: "dictation-xai"))
        #expect(try Keychain.readString(service: service, account: "dictation-xai") == "xai-fixture-roundtrip")
        try keys.delete(for: .xai)
        #expect(!Keychain.exists(service: service, account: "dictation-xai"))
    }
}
