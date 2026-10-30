import AppKit
import PrismKit
import SwiftUI

/// Keys that act on a running recording: cancel, copy, paste and paste-and-Enter.
struct RecordingKeysSection: View {
    let service: DictationService
    @ViewState private var recording: RecordingAction?
    @ViewState private var error: String?

    private var settings: DictationSettings { service.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RecordingAction.allCases) { action in
                row(action)
            }
            if let error {
                DictationNote(Text(verbatim: error), tone: .warning).padding(.vertical, 6)
            }
            PrismSettingsNote(Text("These keys work only while recording, so they never block other apps. Single modifier keys need Accessibility.", bundle: .module))
                .padding(.top, 6)
        }
        .onChange(of: recording) { _, value in service.monitor.setSuspended(value != nil) }
        .onDisappear { service.monitor.setSuspended(false) }
    }

    private func row(_ action: RecordingAction) -> some View {
        let binding = settings.binding(action)
        var options: [(value: RecordingShortcutMode, title: String)] = []
        if action == .paste {
            options.append((.sameAsPrimary, String(localized: "Same as start shortcut · default", bundle: .module)))
        }
        options.append((.custom, String(localized: "Custom", bundle: .module)))
        options.append((.disabled, String(localized: "None", bundle: .module)))
        return PrismSettingsRow(Text(verbatim: action.title), detail: Text(verbatim: action.subtitle)) {
            HStack(spacing: 8) {
                PrismSelect(selection: Binding(get: { binding.mode }, set: { mode in
                    var updated = binding
                    updated.mode = mode
                    if mode == .custom, updated.label.isEmpty { recording = action }
                    apply(updated, to: action)
                }), options: options)
                if binding.mode == .custom {
                    ShortcutRecorderButton(label: binding.label, isRecording: Binding(get: { recording == action }, set: { recording = $0 ? action : nil })) { captured in
                        apply(captured, to: action)
                    }
                }
            }
        }
    }

    private func apply(_ binding: RecordingShortcutSetting, to action: RecordingAction) {
        var next = settings
        next.setBinding(binding, for: action)
        if let primary = service.dictationShortcut?.label, binding.mode == .custom,
           binding.label.replacingOccurrences(of: " ", with: "").lowercased() == primary.replacingOccurrences(of: " ", with: "").lowercased() {
            error = String(localized: "This matches the start shortcut. For paste, choose “Same as start shortcut”.", bundle: .module)
            return
        }
        if binding.mode == .custom, RecordingAction.allCases.contains(where: { $0 != action && next.binding($0).conflicts(with: binding) }) {
            error = String(localized: "Use a different shortcut for each recording action.", bundle: .module)
            return
        }
        error = nil
        service.update(next)
    }
}

/// Records one physical key: a combination, or a single modifier pressed and released alone.
/// Key codes are layout independent, so a Korean input source records the same key as English.
struct ShortcutRecorderButton: View {
    let label: String
    @Binding var isRecording: Bool
    let onCapture: (RecordingShortcutSetting) -> Void
    @ViewState private var monitor: Any?
    @ViewState private var candidate: RecordingShortcutKind?
    @ViewState private var invalid = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(verbatim: isRecording ? String(localized: "Press a key…", bundle: .module)
                 : invalid ? String(localized: "Key not supported", bundle: .module)
                 : label.isEmpty ? String(localized: "Record Shortcut", bundle: .module) : label)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isRecording ? PrismTheme.text : PrismTheme.textSecondary)
                .padding(.horizontal, 12)
                .frame(minWidth: 90, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isRecording ? PrismTheme.surfaceSelected : PrismTheme.surfaceStrong))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isRecording ? PrismTheme.accent.opacity(0.65) : PrismTheme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, value in value ? startMonitoring() : stopMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in isRecording = false }
        .onDisappear { isRecording = false; stopMonitoring() }
    }

    private func startMonitoring() {
        stopMonitoring()
        candidate = nil
        invalid = false
        // Pause the shell's global hotkeys so pressing one records it instead of running its command.
        ShortcutRecording.onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            switch event.type {
            case .leftMouseDown:
                isRecording = false
                return event
            case .flagsChanged:
                handleFlags(event)
                return nil
            case .keyDown:
                guard !event.isARepeat else { return nil }
                candidate = nil
                if let binding = RecordingShortcutSetting.keyCombination(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
                    onCapture(binding)
                    isRecording = false
                } else {
                    invalid = true
                    isRecording = false
                }
                return nil
            default:
                return event
            }
        }
    }

    /// A modifier pressed and released with nothing else in between becomes a single-modifier binding.
    private func handleFlags(_ event: NSEvent) {
        guard let kind = RecordingShortcutKind.forKeyCode(event.keyCode), let flag = kind.modifierFlag else { return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.contains(flag) {
            candidate = flags == flag && candidate == nil ? kind : nil
            if flags != flag { candidate = nil }
        } else if candidate == kind, flags.isEmpty {
            onCapture(.singleModifier(kind))
            isRecording = false
        } else {
            candidate = nil
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            ShortcutRecording.onRecordingChanged?(false)
        }
        monitor = nil
        candidate = nil
    }
}
