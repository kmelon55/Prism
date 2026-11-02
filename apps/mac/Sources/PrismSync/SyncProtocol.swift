import CryptoKit
import Foundation

enum SyncFailure: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}
struct SyncRecord: Codable {
  let key: String
  let revision: Int
  let ciphertext: String
}
struct SyncClip: Codable, Identifiable {
  let id: String
  let deviceId: String
  let ciphertext: String
}
struct SyncDevice: Codable, Identifiable {
  let id: String
  let name: String
  let platform: String
}
struct SyncSettingsResponse: Decodable { let records: [SyncRecord] }
struct SyncClipsResponse: Decodable { let clips: [SyncClip] }
struct SyncDevicesResponse: Decodable { let devices: [SyncDevice] }
struct SyncRegistration: Decodable {
  let id: String
  let token: String
  let owner: String
}
struct SyncRevision: Decodable { let revision: Int }
struct SyncOK: Decodable { let ok: Bool }
struct SyncSecrets: Codable {
  var token: String
  var key: String
}
struct SyncState: Codable {
  var server = ""
  var deviceID = ""
  var owner = ""
  var enabled = false
  var sendClipboard = false
  var localKeys: Set<String> = []
  var revisions: [String: Int] = [:]
  var baseline: [String: String] = [:]
  var transfers: TransferState?
}
enum SyncCrypto {
  static func generateKey() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
  }
  static func key(_ string: String) throws -> SymmetricKey {
    guard let data = Data(base64Encoded: string), data.count == 32 else {
      throw SyncFailure.message("암호화 키는 32바이트 Base64여야 해요.")
    }
    return SymmetricKey(data: data)
  }
  static func seal(_ text: String, key: String, context: String) throws -> String {
    let box = try AES.GCM.seal(
      Data(text.utf8), using: self.key(key), authenticating: Data(context.utf8))
    return box.combined!.base64EncodedString()
  }
  static func open(_ value: String, key: String, context: String, maximum: Int = 67500) throws
    -> String
  {
    guard let data = Data(base64Encoded: value), data.count <= maximum else {
      throw SyncFailure.message("암호화된 데이터가 올바르지 않아요.")
    }
    let plain = try AES.GCM.open(
      AES.GCM.SealedBox(combined: data), using: self.key(key), authenticating: Data(context.utf8))
    guard let text = String(data: plain, encoding: .utf8) else {
      throw SyncFailure.message("텍스트를 읽을 수 없어요.")
    }
    return text
  }
}
enum SyncPreference {
  static let defaults = [
    "theme": "system", "showApplicationIcons": "true", "reduceMotion": "false",
    "backgroundOpacity": "0.64", "backgroundBlur": "12.0",
  ]
  static let titles = [
    "theme": "테마", "showApplicationIcons": "앱 아이콘", "reduceMotion": "동작 줄이기",
    "backgroundOpacity": "배경 불투명도", "backgroundBlur": "배경 흐림",
  ]
  static func valid(_ value: String, for key: String) -> Bool {
    switch key {
    case "theme": ["system", "light", "dark"].contains(value)
    case "showApplicationIcons", "reduceMotion": ["true", "false"].contains(value)
    case "backgroundOpacity": Double(value).map { $0.isFinite && (0.2...1).contains($0) } ?? false
    case "backgroundBlur": Double(value).map { $0.isFinite && (0...32).contains($0) } ?? false
    default: false
    }
  }
  static func read(_ key: String) -> String {
    guard let value = UserDefaults.standard.object(forKey: key) else { return defaults[key] ?? "" }
    if key == "showApplicationIcons" || key == "reduceMotion" {
      return UserDefaults.standard.bool(forKey: key) ? "true" : "false"
    }
    return String(describing: value)
  }
  static func apply(_ value: String, for key: String) throws {
    guard valid(value, for: key) else { throw SyncFailure.message("지원하지 않는 설정이에요.") }
    switch key {
    case "theme": UserDefaults.standard.set(value, forKey: key)
    case "showApplicationIcons", "reduceMotion":
      UserDefaults.standard.set(value == "true", forKey: key)
    default: UserDefaults.standard.set(Double(value), forKey: key)
    }
  }
}

enum SyncMergeDecision: Equatable {
  case keepLocal, upload, adoptRemote, conflict, unchanged
  static func decide(
    localOnly: Bool, local: String, baseline: String, knownRevision: Int,
    remote: String?, remoteRevision: Int?, useRemote: Bool
  ) -> Self {
    if localOnly { return .keepLocal }
    guard let remote, let remoteRevision else { return .upload }
    if remoteRevision != knownRevision {
      if local != baseline && local != remote && !useRemote { return .conflict }
      return .adoptRemote
    }
    return local != baseline ? .upload : .unchanged
  }
}

struct TransferState: Codable {
  var automatic: Set<String> = []
  var published: Set<String> = []
  var revisions: [String: Int] = [:]
  var fingerprints: [String: String] = [:]
  var profileRevisions: [String: Int] = [:]
  var profileFingerprints: [String: String] = [:]
}
struct CollectionResponse: Decodable { let record: SyncRecord? }
struct CollectionPreview {
  let source: String
  let created: Date
  let records: [String: SyncRecord]
  let payloads: [String: Data]
  let localFingerprints: [String: String]
}
