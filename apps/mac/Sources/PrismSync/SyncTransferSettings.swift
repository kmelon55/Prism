import Foundation
import PrismKit
import SwiftUI

struct SyncTransferSettings: View {
  @Bindable var model: SyncModel
  @ViewState private var confirmPublish = false
  var body: some View {
    PrismSettingsGroup(Text(String(localized: "Import and automatic sync", bundle: .module.prismLocalized))) {
      Text(String(localized: "Connecting does not change your settings. Select what to import or sync automatically.", bundle: .module.prismLocalized))
        .font(.caption).foregroundStyle(.secondary)
      ForEach(model.adapters) { adapter in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Toggle(
              adapter.title,
              isOn: Binding(
                get: { model.selectedTransfers.contains(adapter.id) },
                set: { selected in
                  if selected {
                    model.selectedTransfers.insert(adapter.id)
                  } else {
                    model.selectedTransfers.remove(adapter.id)
                  }
                  model.clearPreview()
                }))
            if adapter.sensitive {
              Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel(
                String(localized: "Encrypted API key", bundle: .module.prismLocalized))
            }
            Spacer()
            if model.transferOptions.automatic.contains(adapter.id) {
              Text(String(localized: "Automatic sync", bundle: .module.prismLocalized)).font(.caption)
              Button(String(localized: "Stop", bundle: .module.prismLocalized)) { model.stopAutomatic(adapter.id) }
            }
            if model.transferOptions.published.contains(adapter.id) {
              Text(String(localized: "Device backup", bundle: .module.prismLocalized)).font(.caption)
              Button(String(localized: "Stop backup", bundle: .module.prismLocalized)) { model.stopPublishing(adapter.id) }
            }
          }
          if let message = model.transferMessages[adapter.id] {
            Text(message).font(.caption).foregroundStyle(.orange)
          }
        }
      }
      Text(
        String(localized: "Select API keys by provider. Only selected keys are encrypted and stored, then saved in Keychain on the new device. Custom server keys and URLs are not included yet.", bundle: .module.prismLocalized)
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(String(localized: "Back Up Selected Items", bundle: .module.prismLocalized)) { Task { await model.publishSelected(automatic: false) } }
        Button(String(localized: "Start Sync with This Device's Values", bundle: .module.prismLocalized)) { confirmPublish = true }
      }.disabled(model.selectedTransfers.isEmpty || !model.state.enabled)
      Text(String(localized: "Device backup saves this Mac's changes to the server. Automatic sync shares values in both directions, including deleted notes and snippets. Stopping leaves stored server data in place.", bundle: .module.prismLocalized))
        .font(.caption).foregroundStyle(.secondary)
      Picker(
        String(localized: "Import from", bundle: .module.prismLocalized),
        selection: Binding(
          get: { model.transferSource },
          set: {
            model.transferSource = $0
            model.clearPreview()
          })
      ) {
        Text(String(localized: "Shared settings", bundle: .module.prismLocalized)).tag("shared")
        ForEach(model.devices) { device in Text(device.name).tag(device.id) }
      }
      Button(String(localized: "Preview Selected Items", bundle: .module.prismLocalized)) { Task { await model.previewSelected() } }
        .disabled(model.selectedTransfers.isEmpty || !model.state.enabled)
      if let preview = model.transferPreview {
        Divider()
        Text(String(localized: "Items to import", bundle: .module.prismLocalized)).font(.headline)
        ForEach(model.adapters.filter { model.selectedTransfers.contains($0.id) }) { adapter in
          HStack {
            Text(adapter.title)
            Spacer()
            Text(summary(preview.payloads[adapter.id], adapter: adapter)).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(String(localized: "Selected settings and notes with matching IDs are replaced by imported values. Notes, snippets, and links unique to this device are kept. Unselected items stay unchanged.", bundle: .module.prismLocalized))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(String(localized: "Import Once", bundle: .module.prismLocalized)) { Task { await model.importPreview(automatic: false) } }
          if preview.source == "shared" {
            Button(String(localized: "Import and Sync Automatically", bundle: .module.prismLocalized)) { Task { await model.importPreview(automatic: true) } }
          }
          Button(String(localized: "Cancel", bundle: .module.prismLocalized)) { model.clearPreview() }
        }
      }
    }
    .disabled(model.busy)
    .confirmationDialog(
      String(localized: "Replace the selected shared values with this device's values and start automatic sync?", bundle: .module.prismLocalized), isPresented: $confirmPublish,
      titleVisibility: .visible
    ) {
      Button(String(localized: "Start with Selected Items", bundle: .module.prismLocalized)) { Task { await model.publishSelected(automatic: true) } }
      Button(String(localized: "Cancel", bundle: .module.prismLocalized), role: .cancel) {}
    } message: {
      Text(
        model.adapters.filter { model.selectedTransfers.contains($0.id) }.map(\.title).joined(
          separator: ", "))
    }
  }
  private func summary(_ data: Data?, adapter: SyncTransfer) -> String {
    guard let data else { return String(localized: "No saved items · skipped", bundle: .module.prismLocalized) }
    if adapter.sensitive {
      return (try? JSONDecoder().decode(String?.self, from: data)) != nil
        ? String(localized: "Import saved key", bundle: .module.prismLocalized) : String(localized: "No saved key · remove this device's key", bundle: .module.prismLocalized)
    }
    if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
      return String(localized: "\(array.count) items", bundle: .module.prismLocalized)
    }
    if let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
      return String(localized: "\(values.count) shortcuts", bundle: .module.prismLocalized)
    }
    return String(decoding: data, as: UTF8.self).prefix(80).description
  }
}
