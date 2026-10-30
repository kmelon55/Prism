import PrismKit
import SwiftUI

/// Saved-key status with Change and Delete, or a secure field to save one. Recreate with `.id(provider)` so a
/// typed key never survives a provider switch.
struct APIKeyRow: View {
    let service: DictationService
    let provider: SpeechProvider
    @ViewState private var key = ""
    @ViewState private var editing = false
    @ViewState private var busy = false
    @ViewState private var confirmingDelete = false
    @ViewState private var message: String?
    @ViewState private var failed = false

    private var info: DictationKeyInfo { service.keyInfo(for: provider) }
    private var shared: Bool { DictationKeys.isShared(provider) }

    var body: some View {
        PrismSettingsRow(Text("API key", bundle: .module),
                         detail: Text(shared ? "Shared with the key saved in AI settings." : "Stored in the macOS Keychain.", bundle: .module)) {
            VStack(alignment: .trailing, spacing: 6) {
                if info.configured, !editing {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(PrismTheme.accent)
                        Text(verbatim: info.maskedKey ?? "•••• ••••")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(PrismTheme.textSecondary)
                        Button { editing = true; message = nil } label: { Text("Change", bundle: .module) }
                            .buttonStyle(.prismGhost).disabled(busy)
                        Button { confirmingDelete = true } label: { Text("Delete", bundle: .module) }
                            .buttonStyle(.prismGhost).disabled(busy)
                    }
                } else {
                    HStack(spacing: 6) {
                        SecureField(text: $key, prompt: Text(info.configured ? "New API key" : "Paste API key", bundle: .module)) { EmptyView() }
                            .labelsHidden()
                            .textFieldStyle(.prism)
                            .frame(minWidth: 140, idealWidth: 200, maxWidth: 200)
                            .onSubmit(save)
                        Button(action: save) { Text(busy ? "Saving…" : "Save key", bundle: .module) }
                            .buttonStyle(.prism)
                            .fixedSize()
                            .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if editing {
                            Button { editing = false; key = "" } label: { Text("Cancel", bundle: .module) }.buttonStyle(.prism)
                        }
                    }
                }
                if let message {
                    Text(verbatim: message).font(.system(size: 11)).foregroundStyle(failed ? PrismTheme.warning : PrismTheme.textMuted)
                }
            }
        }
        .confirmationDialog(Text("Delete this API key?", bundle: .module), isPresented: $confirmingDelete) {
            Button(role: .destructive) { remove() } label: { Text("Delete Key", bundle: .module) }
        } message: {
            Text(shared ? "AI chat also uses this key and will stop working until you add it again." : "The saved provider key is removed from the Keychain.", bundle: .module)
        }
    }

    private func save() {
        guard !busy, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busy = true
        let value = key
        Task {
            defer { busy = false }
            do {
                try await service.saveKey(value, for: provider)
                key = ""
                editing = false
                failed = false
                message = String(localized: "Key saved.", bundle: .module)
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }

    private func remove() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await service.deleteKey(for: provider)
                failed = false
                message = String(localized: "Key deleted.", bundle: .module)
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }
}
