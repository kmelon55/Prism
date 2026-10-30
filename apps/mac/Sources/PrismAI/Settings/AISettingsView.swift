import PrismKit
import SwiftUI

/// Settings › AI: default model, provider keys, the custom server, tools and usage.
/// Mirrors the Tauri `AiSettings` page: a current-model block with an accent bar, provider options with a check,
/// the key form, tools and permissions, and the usage report.
struct AISettingsView: View {
    @ViewState private var model: AISettingsModel
    @ViewState private var choosingModel = false

    init(service: AIService) {
        _model = ViewState(initialValue: AISettingsModel(service: service))
    }

    var body: some View {
        PrismSettingsPage(L("AI")) {
            VStack(alignment: .leading, spacing: 0) {
                currentModel
                connection.padding(.top, 18)
                AIToolsSection(model: model).padding(.top, 46)
                AIUsageSection(ledger: model.service.ledger).padding(.top, 24)
                footerNotice.padding(.top, 18)
            }
        }
        .onAppear { model.load() }
        .sheet(isPresented: $choosingModel) {
            ModelPickerView(service: model.service, selection: model.saved, purpose: .settings,
                            onSelect: { try await model.select($0) }, onDismiss: { choosingModel = false })
        }
    }

    // MARK: Current model

    private var currentModel: some View {
        var details = [model.saved.model.isEmpty ? L("Click Choose Model to search and set the default model.")
                                                 : "\(model.saved.provider.name) · \(model.saved.model)"]
        if let active = model.activeModel {
            details.append(L("Input \(AIPrice.format(active.inputPrice)) · Output \(AIPrice.format(active.outputPrice)) / 1M tokens"))
        }
        return PrismCurrentModelBlock(
            eyebrow: Text(L("Current model")),
            title: !model.ready ? L("Checking the saved model…") : model.saved.model.isEmpty ? L("Choose a model") : model.saved.displayName,
            details: details
        ) {
            Button { choosingModel = true } label: {
                PrismTriggerLabel(Text(model.saved.model.isEmpty ? L("Choose model") : L("Change model")))
            }
            .buttonStyle(PrismTriggerButtonStyle())
            .disabled(!model.ready || model.busy)
            .accessibilityLabel(L("Change default model"))
        }
    }

    // MARK: Connection

    private var connection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrismSectionHeading(Text(L("Provider"))) { Text(L("Connect your own API key")) }
                .padding(.bottom, 10)
            providerOptions
            if model.provider == .compatible {
                compatible.padding(.top, 16)
            } else {
                providerKey
            }
            if let error = model.keyError {
                AINote(error, tone: .error).padding(.top, 7)
            }
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { PrismHairline() }
    }

    /// Four equal options; the active one is raised with a light border and a check (`.ai-provider-options`).
    private var providerOptions: some View {
        HStack(spacing: 6) {
            ForEach(AIProvider.displayOrder) { provider in
                let active = provider == model.provider
                Button { model.changeProvider(provider) } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: provider.name).lineLimit(1).minimumScaleFactor(0.85)
                        if active { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(active ? PrismTheme.accentStrong : PrismTheme.text)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? PrismTheme.surfaceSelected : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(active ? PrismTheme.accent : PrismTheme.lineStrong))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .disabled(model.busy || !model.ready)
        .opacity(model.busy || !model.ready ? 0.6 : 1)
    }

    @ViewBuilder
    private var providerKey: some View {
        HStack(spacing: 8) {
            Text(verbatim: model.provider.summary)
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
            Spacer(minLength: 8)
            if let url = model.provider.keyURL {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Text(L("Get a key"))
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 7)
        if model.checking {
            AINote(L("Checking the saved key…"))
        }
        if let info = model.keyInfo, info.configured, !model.editingKey {
            HStack(spacing: 9) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.accent)
                Text(L("Key saved")).font(.system(size: 12, weight: .medium)).foregroundStyle(PrismTheme.text)
                Text(verbatim: info.maskedKey ?? L("Stored in the macOS Keychain"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !info.unlocked {
                    Button(L("Allow Key Use")) { model.unlockKey() }.buttonStyle(.prismGhost).disabled(model.busy || model.checking)
                }
                Button(L("Change")) { model.editingKey = true }.buttonStyle(.prismGhost).disabled(model.busy || model.checking)
                Button(L("Delete")) { model.deleteKey() }.buttonStyle(.prismGhost).disabled(model.busy || model.checking)
            }
            .frame(minHeight: 37)
            if !info.unlocked {
                AINote(L("In the macOS password dialog, choose Always Allow to remember access when restarting Prism. An update may require approval again."))
            }
        } else if !model.checking {
            HStack(spacing: 6) {
                SecureField(text: $model.keyText, prompt: Text(model.editingKey ? L("Paste a new API key") : L("Paste an API key"))) {
                    Text(L("API key"))
                }
                .labelsHidden()
                .textFieldStyle(PrismTextFieldStyle(height: 36))
                .font(.system(size: 13))
                .onSubmit { model.saveKey() }
                Button(model.busy ? L("Saving…") : L("Save Key")) { model.saveKey() }
                    .buttonStyle(.prism)
                    .disabled(model.busy || !model.ready || model.keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.editingKey {
                    Button(L("Cancel")) { model.editingKey = false; model.keyText = "" }.buttonStyle(.prism)
                }
            }
            if model.keyInfo?.configured == false {
                AINote(L("No saved key · Keys are stored in the macOS Keychain.")).padding(.top, 7)
            }
        }
    }

    private var compatible: some View {
        VStack(alignment: .leading, spacing: 12) {
            AIField(label: L("API base URL")) {
                TextField(text: $model.baseURLText, prompt: Text(verbatim: "http://localhost:11434/v1")) { Text(L("API base URL")) }
                    .labelsHidden()
                    .textFieldStyle(PrismTextFieldStyle(height: 36))
            }
            AIField(label: L("API key (optional)")) {
                SecureField(text: $model.compatibleKeyText,
                            prompt: Text(model.connection.hasKey && !model.compatibleChanged ? L("Leave blank to keep the saved key") : L("Leave blank for servers without authentication"))) {
                    Text(L("API key (optional)"))
                }
                .labelsHidden()
                .textFieldStyle(PrismTextFieldStyle(height: 36))
            }
            HStack(spacing: 6) {
                Button(model.busy ? L("Saving…") : L("Save Connection")) { model.saveConnection() }
                    .buttonStyle(.prism)
                    .disabled(model.busy || model.baseURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.connection.hasKey && !model.compatibleChanged {
                    Button(L("Allow Key Use")) { model.unlockCompatible() }.buttonStyle(.prism).disabled(model.busy)
                }
            }
            AINote(L("Use the API base path, including /v1 when required. Keys stay in Keychain and are not shared between server addresses."))
            AIField(label: L("Model ID")) {
                TextField(text: $model.compatibleModelText, prompt: Text(verbatim: "model-name")) { Text(L("Model ID")) }
                    .labelsHidden()
                    .textFieldStyle(PrismTextFieldStyle(height: 36))
                    .onSubmit { model.useCompatibleModel() }
            }
            Button(L("Use Model")) { model.useCompatibleModel() }
                .buttonStyle(.prism)
                .disabled(model.busy || model.compatibleChanged || model.connection.baseUrl.isEmpty
                          || model.compatibleModelText.trimmingCharacters(in: .whitespaces).isEmpty)
            AINote(L("Enter a model ID directly if the server does not provide a model catalog."))
        }
    }

    @ViewBuilder
    private var footerNotice: some View {
        if let error = model.error {
            AINote(error, tone: .error)
        } else {
            Text(verbatim: model.notice ?? L("Click a model to save it. Messages are billed by the selected provider."))
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Tools

/// Tools and permissions (`AiToolSettings`): web search, local file reading with permitted folders, output limit.
private struct AIToolsSection: View {
    let model: AISettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrismSectionHeading(Text(L("Tools and permissions"))) { Text(L("Search automatically · Files with permission")) }
                .padding(.bottom, 10)
            toolRow(icon: "globe", title: L("Automatic web search"),
                    detail: L("AI searches only when needed on supported connections and models. Search queries are sent to the search provider and may incur additional usage charges. Custom API servers do not include web search.")) {
                EmptyView()
            }
            toolRow(icon: "folder", title: L("Allow local file reading"),
                    detail: L("Sends file names and needed text from chosen folders to the conversation's AI provider. Prism never edits files or runs commands. Hidden and key files are excluded.")) {
                Toggle(isOn: Binding(get: { model.tools.localFiles }, set: { model.setLocalFiles($0) })) { EmptyView() }
                    .toggleStyle(.prismCheckbox)
                    .labelsHidden()
                    .accessibilityLabel(L("Allow local file reading"))
                    .disabled(!model.toolsReady || model.busy)
            }
            folders
            outputLimit
            if let error = model.toolsError {
                AINote(error, tone: .error)
            }
        }
        .padding(.top, 22)
        .overlay(alignment: .top) { PrismHairline() }
    }

    private func toolRow<Control: View>(icon: String, title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(PrismTheme.textMuted)
                .frame(width: 17)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) { PrismHairline() }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.tools.folders) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(PrismTheme.textMuted)
                    Text(verbatim: folder.path)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.removeFolder(folder.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.prismGhost)
                    .help(L("Revoke access to \(folder.path)"))
                    .accessibilityLabel(L("Revoke access to \(folder.path)"))
                    .disabled(model.busy)
                }
            }
            Button { model.addFolder() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12))
                    Text(L("Add permitted folder"))
                }
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PrismTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(PrismTheme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.toolsReady || model.busy)
            .opacity(!model.toolsReady || model.busy ? 0.6 : 1)
            Text(L("Text and code files, up to 32 KB each. PDFs and images are not supported yet."))
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
        }
        .padding(.leading, 29)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private var outputLimit: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Output and reasoning limit")).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Text(L("Raise it when a reasoning model runs out before answering. Higher limits can increase usage."))
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PrismSelect(selection: Binding(get: { model.tools.maxOutputTokens }, set: { model.setOutputLimit($0) }),
                        options: AIToolSettings.outputLimits.map { ($0, L("\($0.formatted()) tokens")) })
                .disabled(!model.toolsReady || model.busy)
        }
        .padding(.vertical, 15)
    }
}

// MARK: Small pieces

/// A muted 11 pt note (`.ai-settings-note`), or a red error line (`.ai-settings-error`).
struct AINote: View {
    enum Tone { case note, error }
    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .note) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(tone == .error ? PrismTheme.danger : PrismTheme.textMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled field of the custom server form (`.ai-compatible-settings label`).
private struct AIField<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(PrismTheme.text)
            field()
        }
    }
}
