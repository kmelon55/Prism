import CryptoKit
import Foundation
import PrismKit

extension SyncModel {
  static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  func localData(_ adapter: SyncTransfer) throws -> Data {
    let data = try adapter.read()
    guard data.count <= 1_000_000 else { throw TransferError("이 항목은 1 MB를 초과해 동기화할 수 없어요.") }
    try adapter.validate(data)
    return data
  }
  func context(_ source: String, _ key: String) -> String {
    "prism-v2:\(state.owner):collection:\(source):\(key)"
  }
  func fetchCollection(_ key: String, source: String) async throws -> SyncRecord? {
    guard let secrets else { throw TransferError("서버에 먼저 연결하세요.") }
    let result: CollectionResponse = try await client.request(
      "collections/\(key)?source=\(source)", server: state.server, token: secrets.token)
    return result.record
  }
  func decode(_ record: SyncRecord, source: String, adapter: SyncTransfer) throws -> Data {
    guard let secrets, record.key == adapter.id else { throw TransferError("항목 정보가 일치하지 않아요.") }
    let value = try SyncCrypto.open(
      record.ciphertext, key: secrets.key, context: context(source, adapter.id), maximum: 1_400_000)
    guard let data = Data(base64Encoded: value), data.count <= 1_000_000 else {
      throw TransferError("항목 데이터가 올바르지 않아요.")
    }
    try adapter.validate(data)
    return data
  }
  func upload(_ key: String, data: Data, source: String, revision: Int) async throws -> Int {
    guard let secrets else { throw TransferError("서버에 먼저 연결하세요.") }
    // Base64 inner payload permits any feature's bounded binary representation.
    let cipher = try SyncCrypto.seal(
      data.base64EncodedString(), key: secrets.key, context: context(source, key))
    guard cipher.utf8.count <= 2_000_000 else { throw TransferError("암호화된 항목이 전송 한도를 초과해요.") }
    let raw = try JSONSerialization.data(withJSONObject: [
      "revision": revision, "ciphertext": cipher,
    ])
    let result: SyncRevision = try await client.request(
      "collections/\(key)?source=\(source)", server: state.server, token: secrets.token,
      method: "POST", raw: raw)
    return result.revision
  }
  func persistTransfers(_ value: TransferState) throws {
    var next = state
    next.transfers = value
    // Persist hashes and choices only: never note bodies, provider keys, or decrypted snapshots.
    try JSONFileStore<SyncState>(url: transferStateURL).save(next)
    state = next
  }
  func clearPreview() { transferPreview = nil }
  func stopAutomatic(_ key: String) {
    guard !busy else { return }
    var options = transferOptions
    options.automatic.remove(key)
    do {
      try persistTransfers(options)
      transferMessages[key] = nil
    } catch { status = error.localizedDescription }
  }
  func stopPublishing(_ key: String) {
    guard !busy else { return }
    var options = transferOptions
    options.published.remove(key)
    do { try persistTransfers(options) } catch { status = error.localizedDescription }
  }
  func previewSelected() async {
    guard !busy, state.enabled else { return }
    busy = true
    defer { busy = false }
    transferPreview = nil
    let epoch = generation
    let source = transferSource
    let selected = selectedTransfers
    do {
      var records: [String: SyncRecord] = [:]
      var payloads: [String: Data] = [:]
      var local: [String: String] = [:]
      for adapter in adapters where selected.contains(adapter.id) {
        local[adapter.id] = Self.fingerprint(try localData(adapter))
        if let record = try await fetchCollection(adapter.id, source: source) {
          try check(epoch)
          records[adapter.id] = record
          payloads[adapter.id] = try decode(record, source: source, adapter: adapter)
        }
      }
      try check(epoch)
      guard !payloads.isEmpty else {
        throw TransferError("선택한 항목이 이 기기/공통 저장소에 없어요. 원래 기기에서 먼저 저장하세요.")
      }
      transferPreview = CollectionPreview(
        source: source, created: Date(), records: records, payloads: payloads,
        localFingerprints: local)
      status = "가져올 항목을 확인하세요. API 키 본문은 화면에 표시하지 않아요."
    } catch { status = error.localizedDescription }
  }
  func importPreview(automatic: Bool) async {
    guard !busy, let preview = transferPreview, state.enabled else { return }
    busy = true
    defer {
      busy = false
      transferPreview = nil
    }
    let epoch = generation
    var completed: [String] = []
    do {
      guard Date().timeIntervalSince(preview.created) < 300 else {
        throw TransferError("미리보기가 만료됐어요. 다시 확인하세요.")
      }
      if automatic && preview.source != "shared" {
        throw TransferError("기기 설정은 먼저 한 번 가져온 뒤, 이 기기 값으로 자동 동기화를 시작하세요.")
      }
      // Verify every source revision and every local baseline before the first write.
      for adapter in adapters where preview.payloads[adapter.id] != nil {
        let latest = try await fetchCollection(adapter.id, source: preview.source)
        try check(epoch)
        guard latest?.revision == preview.records[adapter.id]?.revision,
          Self.fingerprint(try localData(adapter)) == preview.localFingerprints[adapter.id]
        else { throw TransferError("미리보기 후 설정이 바뀌었어요. 다시 확인하세요.") }
      }
      for adapter in adapters {
        guard let data = preview.payloads[adapter.id] else { continue }
        // There are no awaits between the final local check and the feature-owned write.
        guard Self.fingerprint(try localData(adapter)) == preview.localFingerprints[adapter.id]
        else { throw TransferError("적용 전에 로컬 값이 바뀌었어요.") }
        try adapter.apply(data, false)
        completed.append(adapter.title)
        if automatic {
          var options = transferOptions
          options.automatic.insert(adapter.id)
          options.revisions[adapter.id] = preview.records[adapter.id]?.revision
          // Merged additional local notes are published on the next sync, not silently forgotten.
          options.fingerprints[adapter.id] = Self.fingerprint(data)
          try persistTransfers(options)
        }
      }
      status = "가져왔어요: " + completed.joined(separator: ", ")
    } catch {
      status =
        (completed.isEmpty ? "" : "적용 완료: \(completed.joined(separator:", ")). ")
        + error.localizedDescription
    }
  }
  func publishSelected(automatic: Bool) async {
    guard !busy, state.enabled else { return }
    busy = true
    defer { busy = false }
    let epoch = generation
    let selected = selectedTransfers
    var completed: [String] = []
    do {
      for adapter in adapters where selected.contains(adapter.id) {
        let data = try localData(adapter)
        let fingerprint = Self.fingerprint(data)
        let source = automatic ? "shared" : state.deviceID
        let remote = try await fetchCollection(adapter.id, source: source)
        try check(epoch)
        guard Self.fingerprint(try localData(adapter)) == fingerprint else {
          throw TransferError("전송 전에 로컬 값이 바뀌었어요. 다시 시도하세요.")
        }
        let revision = try await upload(
          adapter.id, data: data, source: source, revision: remote?.revision ?? 0)
        try check(epoch)
        var options = transferOptions
        if automatic {
          options.automatic.insert(adapter.id)
          options.revisions[adapter.id] = revision
          options.fingerprints[adapter.id] = fingerprint
        } else {
          options.published.insert(adapter.id)
          options.profileRevisions[adapter.id] = revision
          options.profileFingerprints[adapter.id] = fingerprint
        }
        try persistTransfers(options)
        completed.append(adapter.title)
      }
      status =
        (automatic ? "자동 동기화를 시작했어요: " : "이 기기 설정을 서버에 저장했어요: ") + completed.joined(separator: ", ")
    } catch {
      status =
        (completed.isEmpty ? "" : "완료: \(completed.joined(separator:", ")). ")
        + error.localizedDescription
    }
  }
  func syncTransfers(epoch: Int) async throws {
    transferMessages = [:]
    for adapter in adapters {
      var options = transferOptions
      guard options.automatic.contains(adapter.id) || options.published.contains(adapter.id) else {
        continue
      }
      do {
        var data = try localData(adapter)
        var fingerprint = Self.fingerprint(data)
        if options.automatic.contains(adapter.id) {
          let remote = try await fetchCollection(adapter.id, source: "shared")
          try check(epoch)
          guard Self.fingerprint(try localData(adapter)) == fingerprint else { continue }
          let remoteData = try remote.map { try decode($0, source: "shared", adapter: adapter) }
          let remoteHash = remoteData.map(Self.fingerprint)
          let decision = SyncMergeDecision.decide(
            localOnly: false, local: fingerprint,
            baseline: options.fingerprints[adapter.id] ?? fingerprint,
            knownRevision: options.revisions[adapter.id] ?? 0, remote: remoteHash,
            remoteRevision: remote?.revision, useRemote: false)
          switch decision {
          case .conflict: throw TransferError("다른 기기의 수정과 충돌했어요. 미리보기에서 가져오거나 이 기기 값을 공통값으로 선택하세요.")
          case .adoptRemote:
            if let remoteData, let remote {
              try adapter.apply(remoteData, true)
              options.revisions[adapter.id] = remote.revision
              options.fingerprints[adapter.id] = remoteHash
              try persistTransfers(options)
              data = try localData(adapter)
              fingerprint = Self.fingerprint(data)
            }
          case .upload:
            let revision = try await upload(
              adapter.id, data: data, source: "shared", revision: options.revisions[adapter.id] ?? 0
            )
            try check(epoch)
            options.revisions[adapter.id] = revision
            options.fingerprints[adapter.id] = fingerprint
            try persistTransfers(options)
          default: break
          }
        }
        if options.published.contains(adapter.id),
          options.profileFingerprints[adapter.id] != fingerprint
        {
          let remote = try await fetchCollection(adapter.id, source: state.deviceID)
          try check(epoch)
          let revision = try await upload(
            adapter.id, data: data, source: state.deviceID, revision: remote?.revision ?? 0)
          try check(epoch)
          options.profileRevisions[adapter.id] = revision
          options.profileFingerprints[adapter.id] = fingerprint
          try persistTransfers(options)
        }
      } catch is CancellationError { throw CancellationError() } catch {
        transferMessages[adapter.id] = error.localizedDescription
      }
    }
  }
}
