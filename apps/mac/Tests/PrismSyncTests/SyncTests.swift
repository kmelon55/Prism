import Foundation
import Testing

@testable import PrismSync

@Test func syncAuthenticatedEnvelope() throws {
  let key = SyncCrypto.generateKey()
  let cipher = try SyncCrypto.seal("비밀 텍스트", key: key, context: "owner:clip:1")
  #expect(try SyncCrypto.open(cipher, key: key, context: "owner:clip:1") == "비밀 텍스트")
  #expect(throws: (any Error).self) {
    try SyncCrypto.open(cipher, key: SyncCrypto.generateKey(), context: "owner:clip:1")
  }
  #expect(throws: (any Error).self) {
    try SyncCrypto.open(cipher, key: key, context: "other:clip:1")
  }
  #expect(throws: (any Error).self) { try SyncCrypto.key("not a key") }
}
@Test func syncSettingAllowlist() {
  #expect(SyncPreference.valid("dark", for: "theme"))
  #expect(!SyncPreference.valid("NaN", for: "backgroundBlur"))
  #expect(!SyncPreference.valid("100", for: "backgroundOpacity"))
  #expect(!SyncPreference.valid("secret", for: "apiKey"))
}
@Test func syncServerAddress() throws {
  #expect(try SyncClient.validatedServer("https://sync.example.com/") == "https://sync.example.com")
  for value in [
    "http://example.com", "https://user:pass@example.com", "https://example.com/path",
    "https://example.com?token=a",
  ] {
    #expect(throws: (any Error).self) { try SyncClient.validatedServer(value) }
  }
}

@Test func syncOfflineEditsAndDeviceOverrides() {
  #expect(
    SyncMergeDecision.decide(
      localOnly: true, local: "dark", baseline: "light", knownRevision: 1, remote: "system",
      remoteRevision: 2, useRemote: true) == .keepLocal)
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "light", knownRevision: 1, remote: "system",
      remoteRevision: 2, useRemote: false) == .conflict)
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "light", knownRevision: 1, remote: "system",
      remoteRevision: 2, useRemote: true) == .adoptRemote)
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "light", knownRevision: 1, remote: "light",
      remoteRevision: 1, useRemote: false) == .upload)
}
@Test func syncFirstConnectionAndLostAcknowledgement() {
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "dark", knownRevision: 0, remote: "light",
      remoteRevision: 4, useRemote: false) == .adoptRemote)
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "dark", knownRevision: 0, remote: nil,
      remoteRevision: nil, useRemote: false) == .upload)
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "light", knownRevision: 1, remote: "dark",
      remoteRevision: 2, useRemote: false) == .adoptRemote)
  #expect(
    SyncMergeDecision.decide(
      localOnly: false, local: "dark", baseline: "dark", knownRevision: 2, remote: "dark",
      remoteRevision: 2, useRemote: false) == .unchanged)
}

@Test func syncOldStateDoesNotEnableFeatureTransfers() throws {
  let data = Data(
    #"{"server":"https://example.com","deviceID":"old","owner":"personal","enabled":true,"sendClipboard":false,"localKeys":[],"revisions":{},"baseline":{}}"#
      .utf8)
  let state = try JSONDecoder().decode(SyncState.self, from: data)
  #expect(state.enabled)
  #expect(state.transfers == nil)
}
