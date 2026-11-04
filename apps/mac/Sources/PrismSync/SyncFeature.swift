import PrismKit
import SwiftUI

public enum SyncFeature {
  @MainActor public static func make(context: any PrismContext) -> FeatureContribution {
    let model = SyncModel(url: context.paths.file("sync-v1.json"))
    return FeatureContribution(
      settingsPanes: [
        SettingsPane(
          id: "sync", title: String(localized: "Device Sync", bundle: .module.prismLocalized), systemImage: "arrow.triangle.2.circlepath",
          group: .preferences, order: 25,
          keywords: ["sync", "동기화", "기기", "서버", "클립보드", "cloud", "클라우드", "셀프호스팅"]
        ) {
          SyncSettingsView(model: model)
        }
      ], start: { model.start() })
  }
}
struct SyncSettingsView: View {
  @Bindable var model: SyncModel
  @ViewState private var settingUpServer = false

  private var usingServer: Bool { settingUpServer || model.state.enabled }

  var body: some View {
    PrismSettingsPage(String(localized: "Device Sync", bundle: .module.prismLocalized)) {
      connectionOptions
      if !usingServer {
        PrismSettingsGroup {
          Text(String(localized: "Keep settings and clipboard on this device only.", bundle: .module.prismLocalized))
          if !model.state.deviceID.isEmpty {
            Text(String(localized: "Your server connection is saved. Choose Connect Your Server to resume syncing.", bundle: .module.prismLocalized))
              .font(.caption).foregroundStyle(.secondary)
            Button(String(localized: "Disconnect Saved Server", bundle: .module.prismLocalized), role: .destructive) {
              Task { await model.revoke(model.state.deviceID) }
            }.disabled(model.busy)
          }
        }
      } else if model.state.deviceID.isEmpty {
        PrismSettingsGroup(Text(String(localized: "Connect Your Server", bundle: .module.prismLocalized))) {
          Text(String(localized: "Connect to a Prism server you host.", bundle: .module.prismLocalized)).font(.caption).foregroundStyle(.secondary)
          TextField(String(localized: "HTTPS server URL", bundle: .module.prismLocalized), text: $model.server)
          TextField(String(localized: "Device name", bundle: .module.prismLocalized), text: $model.deviceName)
          SecureField(String(localized: "Server connection code", bundle: .module.prismLocalized), text: $model.connectionCode)
          SecureField(String(localized: "Shared encryption key", bundle: .module.prismLocalized), text: $model.encryptionKey)
          HStack {
            Button(String(localized: "Generate Key for First Device", bundle: .module.prismLocalized)) { model.generateKey() }
            Button(String(localized: "Connect", bundle: .module.prismLocalized)) { Task { await model.connect() } }.disabled(model.busy)
          }
          Text(String(localized: "Enter the first device's encryption key on other devices. If you lose the key, server data cannot be decrypted.", bundle: .module.prismLocalized)).font(.caption)
            .foregroundStyle(.secondary)
          if !model.encryptionKey.isEmpty {
            Button(String(localized: "Copy Encryption Key", bundle: .module.prismLocalized)) { model.copy(model.encryptionKey) }
          }
        }
      } else {
        PrismSettingsGroup {
          Text(model.state.server).font(.caption).textSelection(.enabled)
          HStack {
            Button(String(localized: "Sync Now", bundle: .module.prismLocalized)) { Task { await model.sync() } }

          }.disabled(model.busy || !model.state.enabled)
          Text(String(localized: "Checks every minute, or every five minutes in Low Power Mode. Sync pauses during sleep.", bundle: .module.prismLocalized)).font(.caption).foregroundStyle(
            .secondary)
          Button(String(localized: "Copy Key for Another Device", bundle: .module.prismLocalized)) {
            model.showKey()
            model.copy(model.encryptionKey)
            model.encryptionKey = ""
          }
        }
        SyncTransferSettings(model: model)
        PrismSettingsGroup(Text(String(localized: "Share text", bundle: .module.prismLocalized))) {
          Toggle(
            String(localized: "Automatically send newly copied text", bundle: .module.prismLocalized),
            isOn: Binding(get: { model.state.sendClipboard }, set: { model.setClipboard($0) }))
          Text(
            String(localized: "Automatic sending requires clipboard history. Text from excluded apps or marked private is never sent. The latest text is sent at the next sync; quitting clears pending text. The server keeps up to 50 items from the past 24 hours.", bundle: .module.prismLocalized)
          ).font(.caption).foregroundStyle(.secondary)
          TextEditor(text: $model.draft).frame(height: 70)
          Button(String(localized: "Send Text", bundle: .module.prismLocalized)) { Task { await model.sendDraft() } }.disabled(
            model.busy || !model.state.enabled || model.draft.isEmpty
              || model.draft.utf8.count > 32768)
          ForEach(model.clips, id: \.id) { clip in
            HStack {
              Text(clip.text).lineLimit(2)
              Spacer()
              Button(String(localized: "Copy", bundle: .module.prismLocalized)) { model.copy(clip.text) }
            }
          }
        }
        PrismSettingsGroup(Text(String(localized: "Connected devices", bundle: .module.prismLocalized))) {
          ForEach(model.devices) { device in
            HStack {
              Text(device.name + (device.id == model.state.deviceID ? String(localized: " · this device", bundle: .module.prismLocalized) : ""))
              Spacer()
              Button(String(localized: "Disconnect", bundle: .module.prismLocalized), role: .destructive) { Task { await model.revoke(device.id) } }
                .disabled(model.busy)
            }
          }
        }
      }
      Text(model.status.isEmpty ? String(localized: "Enable sync to share settings with connected devices.", bundle: .module.prismLocalized) : model.status).font(.caption).textSelection(.enabled)
    }
  }

  private var connectionOptions: some View {
    PrismSettingsGroup(Text(String(localized: "Connection", bundle: .module.prismLocalized))) {
      Button {
        settingUpServer = false
        model.setEnabled(false)
      } label: {
        HStack {
          Image(systemName: usingServer ? "circle" : "checkmark.circle.fill")
          Text(String(localized: "Use Only on This Device", bundle: .module.prismLocalized))
          Spacer()
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.busy)
      .accessibilityValue(usingServer ? String(localized: "Not selected", bundle: .module.prismLocalized) : String(localized: "Selected", bundle: .module.prismLocalized))

      HStack {
        Image(systemName: "cloud")
        Text("Prism Cloud")
        Spacer()
        Text(String(localized: "Coming soon", bundle: .module.prismLocalized)).font(.caption)
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      Text(String(localized: "The official cloud service is coming soon.", bundle: .module.prismLocalized))
        .font(.caption).foregroundStyle(.secondary)

      Button {
        settingUpServer = true
        if !model.state.deviceID.isEmpty { model.setEnabled(true) }
      } label: {
        HStack {
          Image(systemName: usingServer ? "checkmark.circle.fill" : "circle")
          Text(String(localized: "Connect Your Server", bundle: .module.prismLocalized))
          Spacer()
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.busy)
      .accessibilityValue(usingServer ? String(localized: "Selected", bundle: .module.prismLocalized) : String(localized: "Not selected", bundle: .module.prismLocalized))
    }
  }
}
