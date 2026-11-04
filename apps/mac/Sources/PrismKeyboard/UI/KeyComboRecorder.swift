import AppKit
import PrismKit
import SwiftUI

/// A key field that records any key, with or without modifiers, including Escape and Delete; clicking it again
/// cancels. Shortcut remaps stay off while it listens, so the keys the user presses are recorded as they are.
struct KeyComboRecorder: View {
    @Binding var combo: KeyCombo?
    let onRecordingChanged: (Bool) -> Void

    @ViewState private var isRecording = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Group {
                if isRecording {
                    Text("Type Keys", bundle: .module.prismLocalized)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PrismTheme.text)
                } else if let combo {
                    HStack(spacing: 3) {
                        ForEach(Array(KeyNames.caps(for: combo).enumerated()), id: \.offset) { _, key in KeyCap(key) }
                    }
                } else {
                    Text("Record", bundle: .module.prismLocalized)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PrismTheme.textMuted)
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 88, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isRecording ? PrismTheme.surfaceSelected : PrismTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isRecording ? PrismTheme.lineStrong : PrismTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        onRecordingChanged(true)
        ShortcutRecording.onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags
            var modifiers: KeyModifiers = []
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            onRecordingChanged(false)
            ShortcutRecording.onRecordingChanged?(false)
        }
        isRecording = false
    }
}
