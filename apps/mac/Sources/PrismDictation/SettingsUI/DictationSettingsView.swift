import AVFoundation
import PrismKit
import SwiftUI

/// Settings › Dictation, laid out like the Tauri `DictationSettings` page: the current model, the two enhancement
/// cards, the dictation command, result and recording keys, the waveform overlay, recognition, permissions and
/// recovery.
struct DictationSettingsView: View {
    let service: DictationService
    @ViewState private var showingModelPicker = false
    @ViewState private var notice: String?

    private var settings: DictationSettings { service.settings }
    private var controller: DictationController { service.controller }

    var body: some View {
        PrismSettingsPage(String(localized: "Dictation", bundle: .module)) {
            VStack(alignment: .leading, spacing: 16) {
                currentModel
                EnhancementSection(service: service)
            }
            command
            PrismSettingsGroup {
                delivery
                RecordingKeysSection(service: service)
            }
            overlay
            recognition
            permissions
            recovery
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerSheet(service: service)
        }
        .task {
            service.reloadShortcuts()
            service.localModels.refresh(preferredWhisperPath: settings.whisperPath)
            // Permission changes made in System Settings arrive without a notification.
            while !Task.isCancelled {
                service.refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { service.flush() }
    }

    // MARK: Current model

    private var currentModel: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrismCurrentModelBlock(eyebrow: Text("Current model", bundle: .module), title: currentModelName,
                                   details: [settings.provider.title]) {
                Button { showingModelPicker = true } label: {
                    PrismTriggerLabel(Text("Change model", bundle: .module))
                }
                .buttonStyle(PrismTriggerButtonStyle())
                .disabled(controller.busy)
                .accessibilityLabel(Text("Change dictation model", bundle: .module))
            }
            if let error = service.loadError {
                DictationNote(Text(verbatim: error), tone: .warning)
            }
        }
    }

    private var currentModelName: String {
        switch settings.provider {
        case .local:
            if !settings.model.isEmpty { return settings.model }
            // An empty path would resolve against the working directory, so check it before taking the file name.
            let file = settings.modelPath.isEmpty ? "" : URL(filePath: settings.modelPath).lastPathComponent
            return file.isEmpty ? String(localized: "Choose a model", bundle: .module) : file
        case .xai: return "Grok STT"
        default: return settings.model.isEmpty ? String(localized: "Choose a model", bundle: .module) : settings.model
        }
    }

    // MARK: Command

    /// The dictation command row (`.dictation-command`): glyph, name and the start shortcut as key caps.
    private var command: some View {
        PrismSettingsGroup {
            PrismSettingsRow(Text("Dictation", bundle: .module),
                             detail: Text("Press to start recording, press again to insert into the current app.", bundle: .module)) {
                Image(systemName: "mic").font(.system(size: 17)).foregroundStyle(PrismTheme.text)
            }
            DictationCommandRow(title: String(localized: "Dictation", bundle: .module), systemImage: "mic",
                                shortcut: service.dictationShortcut)
            if !service.unregisteredShortcuts.isEmpty {
                PrismSettingsRow(Text(verbatim: ""), detail: Text("Double-tap shortcuts need Accessibility permission for Prism.", bundle: .module)) {
                    Button { DictationService.openPrivacySettings("Privacy_Accessibility") } label: { Text("Open Settings", bundle: .module) }
                        .buttonStyle(.prism)
                }
            }
            PrismSettingsNote(Text("Change these shortcuts in Prism's command shortcut settings.", bundle: .module))
                .padding(.top, 10)
        }
    }

    // MARK: Result

    @ViewBuilder
    private var delivery: some View {
        PrismSettingsRow(Text("Default action", bundle: .module),
                         detail: Text("What happens when you press the start shortcut again.", bundle: .module)) {
            PrismSelect(selection: binding(\.defaultDelivery), options: [
                (DefaultDelivery.copy, String(localized: "Copy to clipboard only", bundle: .module)),
                (DefaultDelivery.paste, String(localized: "Paste at the insertion point", bundle: .module)),
            ])
        }
        Text("If no insertion point is found, the text is only copied and Enter is not sent.", bundle: .module)
            .font(.system(size: 12))
            .foregroundStyle(PrismTheme.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        PrismSettingsRow(Text("Save dictation results to clipboard history", bundle: .module),
                         detail: Text("Saved when clipboard history is on. Failed recordings and text stay recoverable either way.", bundle: .module)) {
            Toggle(isOn: binding(\.saveToClipboardHistory)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
        }
    }

    // MARK: Overlay

    private var overlay: some View {
        PrismSettingsGroup {
            PrismSettingsRow(Text("Waveform overlay", bundle: .module),
                             detail: Text("Shown near the bottom of the screen without taking focus.", bundle: .module)) {
                Button { service.preview() } label: {
                    Label { Text("Preview waveform", bundle: .module) } icon: { Image(systemName: "play").font(.system(size: 11)) }
                }
                .buttonStyle(.prism)
                .disabled(controller.busy)
            }
            PrismSettingsRow(Text("Show shortcut hints while recording", bundle: .module),
                             detail: Text("Shows the cancel, paste and send keys beside the waveform.", bundle: .module)) {
                Toggle(isOn: overlayBinding(\.showRecordingShortcutHints)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
            }
            PrismSettingsRow(Text("Show transcription status", bundle: .module),
                             detail: Text("Describes the current step beside the waveform while transcribing.", bundle: .module)) {
                Toggle(isOn: overlayBinding(\.showTranscriptionStatus)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
            }
        }
    }

    private func overlayBinding(_ keyPath: WritableKeyPath<DictationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            var next = settings
            next[keyPath: keyPath] = value
            service.update(next)
            controller.updatePreview(settings: next)
        })
    }

    // MARK: Recognition

    private var recognition: some View {
        PrismSettingsGroup(Text("Recognition", bundle: .module)) {
            if settings.provider != .local {
                APIKeyRow(service: service, provider: settings.provider)
                    .id(settings.provider)
            }
            if settings.provider == .custom {
                PrismSettingsRow(Text(verbatim: "API Base URL")) {
                    TextField(text: Binding(get: { settings.baseURL }, set: { value in
                        var next = settings
                        next.baseURL = value
                        service.update(next, delay: .milliseconds(400))
                    }), prompt: Text(verbatim: "https://…/v1")) { Text(verbatim: "API Base URL") }
                    .labelsHidden()
                    .textFieldStyle(.prism)
                    .frame(width: 280)
                }
            }
            PrismSettingsRow(Text("Spoken language", bundle: .module)) {
                DictationOptionButtons(selection: binding(\.language), options: [
                    ("auto", String(localized: "Automatic", bundle: .module)), ("ko", "한국어"), ("en", "English"),
                ])
            }
            PrismDisclosure(Text("Recognition hints and vocabulary", bundle: .module)) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Recognition hint", bundle: .module).font(.system(size: 12)).foregroundStyle(PrismTheme.text)
                    PrismTextEditor(text: Binding(get: { settings.prompt }, set: { value in
                        var next = settings
                        next.prompt = String(value.prefix(2000))
                        service.update(next, delay: .milliseconds(400))
                    }), minHeight: 52)
                    Text("Vocabulary · one per line", bundle: .module).font(.system(size: 12)).foregroundStyle(PrismTheme.text).padding(.top, 6)
                    PrismTextEditor(text: Binding(get: { settings.vocabulary.joined(separator: "\n") }, set: { value in
                        var next = settings
                        next.vocabulary = value.components(separatedBy: "\n")
                        service.update(next, delay: .milliseconds(400))
                    }), minHeight: 72)
                }
                .padding(.leading, 15)
            }
            .padding(.vertical, 12)
            saveStatus
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch service.saveState {
        case .failed(let message):
            PrismSettingsRow(Text(verbatim: message).foregroundStyle(PrismTheme.warning)) {
                Button { service.flush() } label: { Text("Retry", bundle: .module) }.buttonStyle(.prism)
            }
        case .pending:
            DictationNote(Text("Saving…", bundle: .module)).padding(.vertical, 12)
        case .saved:
            DictationNote(Text("Changes are saved automatically.", bundle: .module)).padding(.vertical, 12)
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        PrismSettingsGroup {
            PrismSettingsRow(Text("Permissions", bundle: .module),
                             detail: Text("Recording needs microphone access; insertion needs Accessibility access.", bundle: .module)) {
                Button {
                    service.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 14, height: 30)
                }
                .buttonStyle(.prism)
                .help(Text("Check Again", bundle: .module))
                .accessibilityLabel(Text("Check Again", bundle: .module))
            }
            PermissionRow(title: Text("Microphone", bundle: .module),
                          detail: Text("Used only while a dictation is recording.", bundle: .module),
                          granted: service.microphoneStatus == .authorized) {
                if service.microphoneStatus == .notDetermined {
                    Button { Task { await service.requestMicrophone() } } label: { Text("Request Access", bundle: .module) }
                        .buttonStyle(.prism)
                } else {
                    Button { DictationService.openPrivacySettings("Privacy_Microphone") } label: { Text("Open Settings", bundle: .module) }
                        .buttonStyle(.prism)
                }
            }
            PermissionRow(title: Text("Accessibility", bundle: .module),
                          detail: Text("Needed to paste into other apps and for double-tap and single-modifier shortcuts.", bundle: .module),
                          granted: service.accessibilityTrusted) {
                Button {
                    Permissions.requestAccessibility()
                    DictationService.openPrivacySettings("Privacy_Accessibility")
                } label: { Text("Open Settings", bundle: .module) }
                .buttonStyle(.prism)
            }
        }
    }

    // MARK: Recovery

    private var recovery: some View {
        PrismSettingsGroup {
            PrismSettingsRow(Text("Dictation Recovery", bundle: .module),
                             detail: Text("Original and processed text are saved on this Mac. Failed recordings are kept so your speech is not lost. Open the folder to recover or delete them.", bundle: .module)) {
                Button { service.openRecoveryFolder() } label: { Text("Open recovery folder", bundle: .module) }
                    .buttonStyle(.prism)
            }
            if controller.busy || !controller.lastTranscript.isEmpty || !controller.originalTranscript.isEmpty {
                HStack(spacing: 6) {
                    if let notice { DictationNote(Text(verbatim: notice)) }
                    Spacer()
                    if controller.busy {
                        Button { controller.cancel() } label: {
                            Label { Text("Cancel Dictation", bundle: .module) } icon: { Image(systemName: "xmark") }
                        }
                        .buttonStyle(.prism)
                    }
                    if !controller.originalTranscript.isEmpty {
                        Button { copy(original: true) } label: { Text("Copy original text", bundle: .module) }.buttonStyle(.prism)
                    }
                    if !controller.lastTranscript.isEmpty {
                        Button { copy(original: false) } label: { Text("Copy last result", bundle: .module) }.buttonStyle(.prism)
                    }
                }
                .padding(.vertical, 8)
            }
            if !controller.recoveryWarning.isEmpty {
                DictationNote(Text(verbatim: controller.recoveryWarning), tone: .warning).textSelection(.enabled)
            }
            if controller.shortcutWarning {
                DictationNote(Text("A recording shortcut could not be registered. Check other apps' shortcuts or Accessibility permission.", bundle: .module),
                              tone: .warning)
            }
        }
    }

    private func copy(original: Bool) {
        let saved = original ? controller.copyOriginal(saveToHistory: settings.saveToClipboardHistory)
                             : controller.copyLast(saveToHistory: settings.saveToClipboardHistory)
        notice = saved ? String(localized: "Copied.", bundle: .module) : String(localized: "Could not copy to the clipboard.", bundle: .module)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DictationSettings, Value>) -> Binding<Value> {
        Binding(get: { service.settings[keyPath: keyPath] }, set: { value in
            var next = service.settings
            next[keyPath: keyPath] = value
            service.update(next)
        })
    }
}

/// A start shortcut as key caps, or a muted "Not set".
struct ShortcutLabel: View {
    let shortcut: StartShortcut?

    var body: some View {
        if let shortcut {
            HStack(spacing: 3) {
                ForEach(Array(shortcut.label.split(separator: " ").enumerated()), id: \.offset) { _, key in KeyCap(String(key)) }
            }
        } else {
            Text("Not set", bundle: .module)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(PrismTheme.textMuted)
        }
    }
}

/// One command of the dictation group (`.dictation-command .settings-command-row`): a glyph, the bold name and
/// the start shortcut on the right, above a hairline. The shortcut itself is edited in Commands settings.
struct DictationCommandRow: View {
    let title: String
    let systemImage: String
    let shortcut: StartShortcut?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .frame(width: 27, height: 27)
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 12)
                ShortcutLabel(shortcut: shortcut)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 50)
            Rectangle().fill(PrismTheme.separator).frame(height: 1)
        }
    }
}

/// Toggle-like option buttons (`.dictation-options`): bordered pills, the active one raised with a light border.
struct DictationOptionButtons<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let active = option.value == selection
                Button { selection = option.value } label: {
                    Text(verbatim: option.title)
                        .font(.system(size: 12))
                        .foregroundStyle(active ? PrismTheme.text : PrismTheme.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? PrismTheme.surfaceSelected : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? PrismTheme.accent.opacity(0.6) : PrismTheme.line))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

/// An 11 pt muted line, or a warning in the theme's warning tone.
struct DictationNote: View {
    enum Tone { case note, warning }
    let text: Text
    let tone: Tone

    init(_ text: Text, tone: Tone = .note) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        text
            .font(.system(size: 11))
            .foregroundStyle(tone == .warning ? PrismTheme.warning : PrismTheme.textMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionRow<Action: View>: View {
    let title: Text
    let detail: Text
    let granted: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        PrismSettingsRow(title + Text(verbatim: " · ") + (granted ? Text("Allowed", bundle: .module) : Text("Needs access", bundle: .module)),
                         detail: detail) {
            if granted {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(PrismTheme.textMuted)
            } else {
                action()
            }
        }
    }
}
