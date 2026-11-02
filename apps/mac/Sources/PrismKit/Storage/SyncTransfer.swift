import Foundation

/// Feature-owned export/import adapters. Sync never reads arbitrary files or arbitrary keychain services.
@MainActor
public struct SyncTransfer: Identifiable {
  public let id: String
  public let title: String
  public let sensitive: Bool
  public let read: () throws -> Data
  public let validate: (Data) throws -> Void
  /// replace is true only after the user joins ongoing synchronization; one-time imports merge library data.
  public let apply: (Data, Bool) throws -> Void
  public init(
    id: String, title: String, sensitive: Bool = false, read: @escaping () throws -> Data,
    validate: @escaping (Data) throws -> Void, apply: @escaping (Data, Bool) throws -> Void
  ) {
    self.id = id
    self.title = title
    self.sensitive = sensitive
    self.read = read
    self.validate = validate
    self.apply = apply
  }
}
@MainActor public enum SyncTransfers {
  public static var registered: [String: SyncTransfer] = [:]
  public static func register(_ adapter: SyncTransfer) { registered[adapter.id] = adapter }
}
public enum TransferCodec {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}
public struct TransferError: LocalizedError {
  public let errorDescription: String?
  public init(_ message: String) { errorDescription = message }
}
