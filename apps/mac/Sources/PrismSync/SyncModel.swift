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
  var status = ""
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
            else { throw TransferError(String(localized: "The settings format is invalid.", bundle: .module.prismLocalized)) }
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
    } catch { status = String(localized: "Could not read connection details from Keychain: \(error.localizedDescription)", bundle: .module.prismLocalized) }
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
      status = enabled ? String(localized: "Starting server sync.", bundle: .module.prismLocalized) : String(localized: "Sync stopped. Data stays on this device.", bundle: .module.prismLocalized)
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
      status = String(localized: "Connected. Checking shared settings.", bundle: .module.prismLocalized)
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
        ? String(localized: "Synced · \(Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(PrismLanguage.locale)))", bundle: .module.prismLocalized)
        : String(localized: "Some items need attention. Check their status.", bundle: .module.prismLocalized)
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
      status = String(localized: "Waiting to send. The latest text will be sent at the next sync.", bundle: .module.prismLocalized)
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
    status = String(localized: "Copied.", bundle: .module.prismLocalized)
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
        status = String(localized: "This device has been disconnected.", bundle: .module.prismLocalized)
      }
    } catch { status = error.localizedDescription }
  }
}
