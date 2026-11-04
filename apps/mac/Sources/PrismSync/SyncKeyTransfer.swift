import Foundation
import PrismKit
import Security

/// Fixed provider keys only. Sync's own token/key and arbitrary Keychain records are never exported.
enum SyncKeyTransfer {
  static let changed = Notification.Name("dev.prism.sync.providerKeysChanged")
  static func read(_ account: String) throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: AppPaths.keychainService("ai"), kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
      "u_AuthUI": "u_AuthUIF",
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return try TransferCodec.encode(Optional<String>.none) }
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw TransferError(String(localized: "Allow key access in API settings and try again. Sync was skipped because the key could not be read.", bundle: .module.prismLocalized))
    }
    return try TransferCodec.encode(Optional(value))
  }
  static func decode(_ data: Data) throws -> String? {
    let value = try JSONDecoder().decode(String?.self, from: data)
    if let value {
      guard !value.isEmpty, value.utf8.count <= 4096,
        value.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
      else { throw TransferError(String(localized: "The API key format is invalid.", bundle: .module.prismLocalized)) }
    }
    return value
  }
  @MainActor static func register() {
    for (account, title) in [
      ("openai", "OpenAI API key"), ("vercel", "Vercel API key"), ("openrouter", "OpenRouter API key"),
      ("dictation-groq", "Groq speech API key"), ("dictation-xai", "xAI speech API key"),
    ] {
      SyncTransfers.register(
        SyncTransfer(
          id: "key." + account, title: String(localized: String.LocalizationValue(title), bundle: .module.prismLocalized), sensitive: true, read: { try read(account) },
          validate: { _ = try decode($0) },
          apply: { data, _ in
            if let value = try decode(data) {
              try Keychain.save(
                Data(value.utf8), service: AppPaths.keychainService("ai"), account: account)
            } else {
              try Keychain.delete(service: AppPaths.keychainService("ai"), account: account)
            }
            NotificationCenter.default.post(name: changed, object: nil)
          }))
    }
  }
}
