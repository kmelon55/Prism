import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Pauses global hotkeys while a recorder listens, so pressing an existing shortcut records it
/// instead of running its command.
@MainActor
public enum ShortcutRecording {
    public static var onRecordingChanged: ((Bool) -> Void)?
}

/// A System Settings style shortcut field. Click, then press the combination. Escape cancels and
/// Delete clears. A shortcut needs ⌘, ⌃ or ⌥ unless it is a function key.
public struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var placeholder: Text

    @ViewState private var isRecording = false
    @ViewState private var monitor: Any?

    public init(shortcut: Binding<Shortcut?>, placeholder: Text? = nil) {
        _shortcut = shortcut
        self.placeholder = placeholder ?? Text("Record Hotkey", bundle: .module)
    }

    /// Tauri's `.command-hotkey`: quiet text until a shortcut exists, then key caps; a small × clears it.
    public var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Group {
                    if isRecording {
                        Text("Type Shortcut", bundle: .module)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PrismTheme.text)
                    } else if let shortcut {
                        HStack(spacing: 3) {
                            ForEach(Array(shortcut.displayKeys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
                        }
                    } else {
                        placeholder
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PrismTheme.textMuted)
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 96, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isRecording ? PrismTheme.surfaceSelected : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isRecording ? PrismTheme.lineStrong : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PrismTheme.textMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Remove Shortcut", bundle: .module))
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        ShortcutRecording.onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            if code == kVK_Escape {
                stop()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if (code == kVK_Delete || code == kVK_ForwardDelete) && modifiers.isEmpty {
                shortcut = nil
                stop()
                return nil
            }
            let isFunctionKey = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].contains(code)
            guard isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            shortcut = Shortcut(keyCode: UInt32(code), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { ShortcutRecording.onRecordingChanged?(false) }
        isRecording = false
    }
}
