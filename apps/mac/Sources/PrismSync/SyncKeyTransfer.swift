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
      throw TransferError("API 설정에서 키 사용을 허용한 뒤 다시 시도하세요. 키를 읽을 수 없어 동기화를 건너뛰었어요.")
    }
    return try TransferCodec.encode(Optional(value))
  }
  static func decode(_ data: Data) throws -> String? {
    let value = try JSONDecoder().decode(String?.self, from: data)
    if let value {
      guard !value.isEmpty, value.utf8.count <= 4096,
        value.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
      else { throw TransferError("API 키 형식이 올바르지 않아요.") }
    }
    return value
  }
  @MainActor static func register() {
    for (account, title) in [
      ("openai", "OpenAI API 키"), ("vercel", "Vercel API 키"), ("openrouter", "OpenRouter API 키"),
      ("dictation-groq", "Groq 음성 API 키"), ("dictation-xai", "xAI 음성 API 키"),
    ] {
      SyncTransfers.register(
        SyncTransfer(
          id: "key." + account, title: title, sensitive: true, read: { try read(account) },
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
