// Native window verification with a simulated meter. Does not record or call STT.
import AppKit
import Foundation
import Carbon.HIToolbox
@MainActor private final class PreviewRecorder: DictationRecording {
    var onLevel: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    func start() async throws { onLevel?(0.5) }
    func stop() -> URL? { nil }
}
@MainActor private final class OverlayDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController(recorder: PreviewRecorder())
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            controller.toggle(fallbackPID: 0)
            controller.configure("""
            {"provider":"local","model":"","baseURL":"","language":"auto","prompt":"","vocabulary":[],"whisperPath":"/fixture","modelPath":"/fixture.bin","uiLanguage":"ko","apiKey":"","primaryShortcutLabel":"⌥ D"}
            """, session: 1)
            try? await Task.sleep(for: .seconds(1))
            guard let panel = NSApplication.shared.windows.first(where: { $0 is NSPanel && $0.isVisible }), let view = panel.contentView else { fatalError("Overlay not visible") }
            precondition(!panel.isKeyWindow)
            precondition(panel.styleMask.contains(.nonactivatingPanel))
            let expectedWidth = min(440, 150 + CGFloat(controller.recordingHints.count) * 90) + 24
            precondition(panel.frame.size == NSSize(width: expectedWidth, height: 74))
            precondition(panel.ignoresMouseEvents && !panel.hasShadow && panel.level == .floating)
            if #available(macOS 26.0, *) {
                let glass = view.subviews.compactMap { $0 as? NSGlassEffectView }.first!
                precondition(glass.style == .clear && glass.tintColor == nil && glass.alphaValue == 0.5)
                precondition(glass.cornerRadius == 25 && glass.frame.origin == NSPoint(x: 12, y: 12))
                precondition(view.subviews.count == 2 && view.subviews[1].frame == glass.frame)
            }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
            precondition(abs(panel.frame.minY - (screen.visibleFrame.minY + max(76, screen.visibleFrame.height * 0.14))) < 1)
            if CommandLine.arguments.count > 1, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: representation)
                if let data = representation.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
            }
            if CommandLine.arguments.count > 1, CGPreflightScreenCaptureAccess() {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), CommandLine.arguments[1].replacingOccurrences(of: ".png", with: "-composited.png")]
                try? capture.run(); capture.waitUntilExit()
                print("Composited window capture status: \(capture.terminationStatus)")
            }
            print("PASS: Whisp recording capsule, hint layout, clear glass, sibling hosting, pointer passthrough and original screen position; width \(expectedWidth) (simulated meter)")
            controller.cancel()
            controller.preview()
            try? await Task.sleep(for: .seconds(3.2))
            precondition(panel.frame.size == NSSize(width: 244, height: 74))
            print("PASS: Whisp transcribing capsule is 220 × 50 with 12-point window margins")
            controller.fail("Fixture permission error")
            precondition(panel.frame.size == NSSize(width: 354, height: 82))
            print("PASS: Whisp toast is 330 × 58 with original window margins")
            controller.cancel()
            precondition(!panel.isVisible)
            print("PASS: cancellation hides the panel")
            controller.preview("{\"showRecordingShortcutHints\":false,\"showTranscriptionStatus\":false}")
            precondition(panel.frame.size == NSSize(width: 188, height: 74))
            precondition(abs(panel.frame.minY - (screen.visibleFrame.minY + max(76, screen.visibleFrame.height * 0.14))) < 1)
            try? await Task.sleep(for: .seconds(3.2))
            precondition(panel.frame.size == NSSize(width: 188, height: 74))
            precondition(controller.overlayPreviewPhase == "transcribing")
            controller.cancel()
            print("PASS: both Whisp details can be hidden independently of phase; compact waveform retains the original screen position")
            let controls = RecordingControls()
            var cancelled = 0; var sent = 0
            controls.onCancel = { cancelled += 1 }; controls.onSend = { sent += 1 }
            controls.install(recording: true)
            precondition(controls.cancelRegistered && controls.sendRegistered)
            func dispatch(signature: OSType, id: UInt32) -> OSStatus {
                var event: EventRef?
                CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
                guard let event else { fatalError("Could not create key fixture") }
                defer { ReleaseEvent(event) }
                var identifier = EventHotKeyID(signature: signature, id: id)
                SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier)
                return SendEventToEventTarget(event, GetApplicationEventTarget())
            }
            precondition(dispatch(signature: 0x50524454, id: 2) == noErr && sent == 1)
            precondition(dispatch(signature: 0x50524454, id: 1) == noErr && cancelled == 1)
            precondition(dispatch(signature: 0x54455354, id: 1) != noErr && cancelled == 1)
            controls.install(recording: false)
            precondition(!controls.sendRegistered && controls.cancelRegistered)
            var pasted = 0; var copied = 0
            controls.onPaste = { pasted += 1 }; controls.onCopy = { copied += 1 }
            controls.settings.recordingCancelShortcut = RecordingShortcutSetting(mode: .disabled, keyCode: 53, modifiers: 0, label: "Esc")
            controls.settings.recordingCopyShortcut = RecordingShortcutSetting(mode: .custom, keyCode: 20, modifiers: 6912, label: "⌃⌥⇧⌘3")
            controls.settings.recordingPasteShortcut = RecordingShortcutSetting(mode: .custom, keyCode: 18, modifiers: 6912, label: "⌃⌥⇧⌘1")
            controls.settings.recordingPasteAndEnterShortcut = RecordingShortcutSetting(mode: .custom, keyCode: 19, modifiers: 6912, label: "⌃⌥⇧⌘2")
            controls.install(recording: true)
            precondition(!controls.cancelRegistered && controls.registered(3) && controls.registered(4) && controls.sendRegistered)
            precondition(dispatch(signature: 0x50524454, id: 3) == noErr && pasted == 1)
            precondition(dispatch(signature: 0x50524454, id: 4) == noErr && copied == 1)
            precondition(dispatch(signature: 0x50524454, id: 2) == noErr && sent == 2)
            precondition(dispatch(signature: 0x50524454, id: 1) != noErr && cancelled == 1)
            controls.settings.recordingPasteAndEnterShortcut = controls.settings.recordingPasteShortcut
            controls.install(recording: true)
            precondition(controls.failedIDs.contains(2) && !controls.sendRegistered)
            print("PASS: configured copy/paste/send keys, disabled cancel and registration conflict handling (synthetic Carbon events)")
            controls.remove(); precondition(!controls.cancelRegistered)
            print("PASS: scoped Return/Esc dispatch, other hotkey passthrough and recording control cleanup (synthetic Carbon events)")
            NSApplication.shared.terminate(nil)
        }
    }
}
@main struct OverlayCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = OverlayDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
