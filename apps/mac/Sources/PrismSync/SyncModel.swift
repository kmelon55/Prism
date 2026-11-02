import AppKit
import Observation
import PrismKit

@MainActor @Observable
final class SyncModel {
  var server = ""
  var connectionCode = ""
  var encryptionKey = ""
  var deviceName = Host.current().localizedName ?? "Mac"
  var state: SyncState
  var devices: [SyncDevice] = []
  var clips: [(id: String, text: String)] = []
  var draft = ""
  var status = "동기화를 켜면 연결한 기기와 설정을 공유해요."
  var busy = false
  var selectedTransfers: Set<String> = []
  var transferSource = "shared"
  var transferPreview: CollectionPreview?
  var transferMessages: [String: String] = [:]
  var transferOptions: TransferState { state.transfers ?? TransferState() }
  var adapters: [SyncTransfer] { SyncTransfers.registered.values.sorted { $0.id < $1.id } }
  private let store: JSONFileStore<SyncState>
  let transferStateURL: URL
  let client: any SyncTransport
  var secrets: SyncSecrets?
  private var loop: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  var generation = 0
  private var failures = 0
  private var sleeping = false
  private var queuedClip: (id: String, ciphertext: String)?
  private let service = AppPaths.keychainService("sync")

  init(url: URL, client: any SyncTransport = SyncClient()) {
    self.client = client
    transferStateURL = url
    store = JSONFileStore(url: url)
    state = store.load() ?? SyncState()
    server = state.server
    SyncKeyTransfer.register()
    for key in SyncPreference.defaults.keys {
      SyncTransfers.register(
        SyncTransfer(
          id: key, title: SyncPreference.titles[key] ?? key,
          read: {
            Data(SyncPreference.read(key).utf8)
          },
          validate: { data in
            guard let value = String(data: data, encoding: .utf8),
              SyncPreference.valid(value, for: key)
            else { throw TransferError("설정 형식이 올바르지 않아요.") }
          },
          apply: { data, _ in
            let value = String(decoding: data, as: UTF8.self)
            try SyncPreference.apply(value, for: key)
            if key == "theme" {
              NSApp.appearance =
                value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
            }
          }))
    }
  }
  func start() {
    do {
      if !state.deviceID.isEmpty,
        let data = try Keychain.read(service: service, account: state.deviceID)
      {
        secrets = try JSONDecoder().decode(SyncSecrets.self, from: data)
      }
    } catch { status = "키체인 연결 정보를 읽지 못했어요: \(error.localizedDescription)" }
    let workspace = NSWorkspace.shared.notificationCenter
    observers.append(
      workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          self?.sleeping = true
          self?.stopLoop()
        }
      })
    observers.append(
      workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          self?.sleeping = false
          self?.schedule()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .init("dev.prism.clipboard.capturedText"), object: nil, queue: .main
      ) { [weak self] note in
        let text = note.userInfo?["text"] as? String
        Task { @MainActor in
          guard let self, let text, self.state.enabled, self.state.sendClipboard else { return }
          self.enqueue(text)
        }
      })
    schedule()
  }
  func save() throws { try store.save(state) }
  func setEnabled(_ enabled: Bool) {
    state.enabled = enabled
    if !enabled {
      queuedClip = nil
      transferPreview = nil
    }
    do {
      try save()
      status = enabled ? "서버 동기화를 시작해요." : "동기화를 멈췄어요. 이 기기에서만 사용해요."
      schedule()
    } catch {
      state.enabled = false
      stopLoop()
      status = error.localizedDescription
    }
  }
  func setClipboard(_ enabled: Bool) {
    state.sendClipboard = enabled
    if !enabled {
      queuedClip = nil
      transferPreview = nil
    }
    do { try save() } catch {
      state.sendClipboard = false
      status = error.localizedDescription
    }
  }
  func generateKey() { encryptionKey = SyncCrypto.generateKey() }
  func showKey() { encryptionKey = secrets?.key ?? encryptionKey }
  func connect() async {
    guard !busy, state.deviceID.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      let address = try SyncClient.validatedServer(server)
      _ = try SyncCrypto.key(encryptionKey)
      let registration: SyncRegistration = try await client.request(
        "pair", server: address, token: connectionCode, method: "POST",
        body: ["name": deviceName, "platform": "mac"])
      let credentials = SyncSecrets(token: registration.token, key: encryptionKey)
      try Keychain.save(
        JSONEncoder().encode(credentials), service: service, account: registration.id)
      var next = SyncState()
      next.server = address
      next.deviceID = registration.id
      next.owner = registration.owner
      next.enabled = true
      next.baseline = Dictionary(
        uniqueKeysWithValues: SyncPreference.defaults.keys.map { ($0, SyncPreference.read($0)) })
      try store.save(next)
      state = next
      secrets = credentials
      connectionCode = ""
      encryptionKey = ""
      status = "연결했어요. 공통 설정을 확인해요."
      schedule()
    } catch { status = error.localizedDescription }
  }
  private func stopLoop() {
    generation += 1
    loop?.cancel()
    loop = nil
  }
  private func schedule() {
    stopLoop()
    guard state.enabled, secrets != nil, !sleeping else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.sync()
        let base = ProcessInfo.processInfo.isLowPowerModeEnabled ? 300.0 : 60.0
        let delay = min(900, base * pow(2, Double(min(self.failures, 4))))
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      }
    }
  }
  func check(_ epoch: Int) throws {
    guard epoch == generation, state.enabled, !Task.isCancelled else { throw CancellationError() }
  }
  func sync() async {
    guard !busy, state.enabled, let secrets else { return }
    busy = true
    defer { busy = false }
    let epoch = generation
    do {
      try await syncTransfers(epoch: epoch)
      if let pending = queuedClip {
        let _: SyncOK = try await client.request(
          "clips", server: state.server, token: secrets.token, method: "POST",
          body: ["id": pending.id, "ciphertext": pending.ciphertext])
        try check(epoch)
        if queuedClip?.id == pending.id { queuedClip = nil }
      }
      let shared: SyncClipsResponse = try await client.request(
        "clips", server: state.server, token: secrets.token)
      try check(epoch)
      clips = try shared.clips.filter { $0.deviceId != state.deviceID }.map {
        (
          $0.id,
          try SyncCrypto.open(
            $0.ciphertext, key: secrets.key, context: "prism-v1:\(state.owner):clip:\($0.id)")
        )
      }
      let listed: SyncDevicesResponse = try await client.request(
        "devices", server: state.server, token: secrets.token)
      try check(epoch)
      devices = listed.devices
      failures = 0
      status =
        transferMessages.isEmpty
        ? "동기화했어요 · \(Date().formatted(date:.omitted,time:.shortened))"
        : "확인이 필요한 항목이 있어요. 항목별 상태를 확인하세요."
    } catch is CancellationError {} catch {
      failures += 1
      status = error.localizedDescription
    }
  }
  func enqueue(_ text: String) {
    guard state.enabled, let secrets, !text.isEmpty, text.utf8.count <= 32768 else { return }
    do {
      let id = UUID().uuidString.lowercased()
      queuedClip = (
        id,
        try SyncCrypto.seal(text, key: secrets.key, context: "prism-v1:\(state.owner):clip:\(id)")
      )
      status = "전송 대기 중이에요. 최신 텍스트 한 개를 다음 동기화 때 보내요."
    } catch { status = error.localizedDescription }
  }
  func sendDraft() async {
    enqueue(draft)
    await sync()
  }
  func copy(_ text: String) {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    // Existing capture privacy policy excludes this type, preventing a cross-device echo.
    item.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([item])
    status = "복사했어요."
  }
  func revoke(_ id: String) async {
    guard !busy, let secrets else { return }
    busy = true
    defer { busy = false }
    transferPreview = nil
    do {
      let _: SyncOK = try await client.request(
        "devices/" + id, server: state.server, token: secrets.token, method: "DELETE")
      devices.removeAll { $0.id == id }
      if id == state.deviceID {
        stopLoop()
        queuedClip = nil
        try Keychain.delete(service: service, account: state.deviceID)
        state = SyncState()
        self.secrets = nil
        clips = []
        try save()
        status = "이 기기의 연결을 해제했어요."
      }
    } catch { status = error.localizedDescription }
  }
}
