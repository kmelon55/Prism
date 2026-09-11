// Synthetic NSEvents only. No posted keystrokes, recording, insertion or STT.
import AppKit
@main struct ModifierShortcutCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let denied = PrismModifierShortcuts(isTrusted: { false })
        precondition(denied.register(0) == 1)
        let monitor = PrismModifierShortcuts(isTrusted: { true })
        precondition(monitor.register(0) == 0)
        precondition(monitor.register(0) == 2)
        defer { for kind: UInt32 in 0..<4 { monitor.unregister(kind) } }
        let controls = RecordingControls(modifierShortcuts: monitor, isTrusted: { true }, modifierFlags: { .control })
        controls.settings.recordingCancelShortcut = RecordingShortcutSetting(mode: .disabled, keyCode: 53, modifiers: 0, label: "")
        controls.settings.recordingPasteAndEnterShortcut = RecordingShortcutSetting(mode: .custom, kind: .singleControl, keyCode: 0, modifiers: 0, label: "⌃")
        controls.settings.primaryDoubleModifier = 0
        var starts = 0; var sends = 0; var pastes = 0
        monitor.onTrigger = { kind in
            precondition(kind == 0)
            if controls.sendRegistered { pastes += 1; controls.remove() }
            else { starts += 1; controls.install(recording: true) }
        }
        controls.onSend = { sends += 1; controls.remove() }
        func event(_ down: Bool, _ time: Double, _ type: NSEvent.EventType = .flagsChanged) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: down ? .control : [], timestamp: time, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: type == .flagsChanged ? 59 : 0)!
        }
        func dispatch(_ down: Bool, _ time: Double, _ type: NSEvent.EventType = .flagsChanged) {
            let e = event(down, time, type); monitor.handle(e); controls.handleRecordingModifier(e)
        }
        dispatch(true, 0); dispatch(false, 0.1); dispatch(true, 0.3)
        precondition(starts == 1 && sends == 0 && controls.sendRegistered)
        dispatch(false, 0.4)
        precondition(sends == 0, "Opening chord release must not send")
        dispatch(true, 1); dispatch(true, 1.05, .keyDown); dispatch(false, 1.1)
        precondition(sends == 0, "Control+A must not send")
        dispatch(true, 2); dispatch(false, 2.1)
        precondition(sends == 0, "Single Ctrl must wait for the second tap")
        try await Task.sleep(for: .seconds(0.46))
        precondition(sends == 1 && starts == 1 && !controls.sendRegistered)
        dispatch(true, 2.2); dispatch(false, 2.3)
        precondition(starts == 1, "Send must not arm a new global double tap")
        try await Task.sleep(for: .seconds(0.45))
        // Exercise both monitor callback orders. The primary double tap wins;
        // its second release must never schedule a later single-send action.
        for controlsFirst in [false, true] {
            controls.install(recording: true)
            controls.handleRecordingModifier(event(false, 5)) // opening Ctrl release
            func recordingDispatch(_ down: Bool, _ time: Double, _ type: NSEvent.EventType = .flagsChanged) {
                let e = event(down, time, type)
                if controlsFirst { controls.handleRecordingModifier(e); monitor.handle(e) }
                else { monitor.handle(e); controls.handleRecordingModifier(e) }
            }
            recordingDispatch(true, 6); recordingDispatch(false, 6.1)
            try await Task.sleep(for: .seconds(0.1))
            precondition(sends == 1, "First tap must not send")
            recordingDispatch(true, 6.25); recordingDispatch(false, 6.3)
            precondition(pastes == (controlsFirst ? 2 : 1) && sends == 1)
            try await Task.sleep(for: .seconds(0.46))
            precondition(sends == 1, "Double Ctrl must cancel pending Send")
        }
        controls.install(recording: true)
        controls.handleRecordingModifier(event(false, 7))
        dispatch(true, 7.1); dispatch(false, 7.2)
        controls.remove()
        try await Task.sleep(for: .seconds(0.46))
        precondition(sends == 1, "Teardown must cancel the pending single tap")
        monitor.onTrigger = { _ in starts += 1 }
        monitor.capture("fixture", active: true)
        dispatch(true, 3); dispatch(false, 3.1); dispatch(true, 3.2); dispatch(false, 3.3)
        precondition(starts == 1, "Recording a shortcut must suppress its existing action")
        monitor.capture("fixture", active: false)
        dispatch(true, 4); dispatch(false, 4.1); dispatch(true, 4.6); dispatch(false, 4.7)
        precondition(starts == 1, "A tap after the 0.42-second limit must not trigger")
        dispatch(true, 4.8); dispatch(false, 4.9)
        precondition(starts == 2)
        monitor.unregister(0)
        for kind: UInt32 in 1..<4 {
            precondition(monitor.register(kind) == 0)
            var fired = 0; monitor.onTrigger = { received in precondition(received == kind); fired += 1 }
            for (down, time) in [(true, 10.0), (false, 10.1), (true, 10.2), (false, 10.3)] {
                monitor.handle(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? PrismModifierShortcuts.flags[Int(kind)] : [], timestamp: time, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: [59, 58, 56, 55][Int(kind)])!)
            }
            precondition(fired == 1); monitor.unregister(kind)
        }
        precondition(monitor.register(0) == 0)
        precondition(monitor.register(1) == 0)
        var kinds: [UInt32] = []
        monitor.onTrigger = { kinds.append($0) }
        let dual = RecordingControls(modifierShortcuts: monitor, isTrusted: { true }, modifierFlags: { [] })
        dual.settings.primaryDoubleModifier = 0
        dual.settings.additionalDoubleModifiers = [0,1]
        dual.settings.recordingCancelShortcut = RecordingShortcutSetting(mode: .disabled, keyCode: 53, modifiers: 0, label: "")
        dual.settings.recordingCopyShortcut = RecordingShortcutSetting(mode: .custom, kind: .singleOption, keyCode: 0, modifiers: 0, label: "⌥")
        dual.settings.recordingPasteAndEnterShortcut = RecordingShortcutSetting(mode: .custom, kind: .singleControl, keyCode: 0, modifiers: 0, label: "⌃")
        var singles = 0
        dual.onCopy = { singles += 1 }; dual.onSend = { singles += 1 }
        dual.install(recording: true)
        for kind: UInt32 in 0..<2 {
            for (down, time) in [(true, 20.0), (false, 20.1), (true, 20.2)] {
                let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? PrismModifierShortcuts.flags[Int(kind)] : [], timestamp: time + Double(kind), windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: kind == 0 ? 59 : 58)!
                dual.handleRecordingModifier(e); monitor.handle(e)
            }
        }
        precondition(kinds == [0,1], "Both ordinary and prompt double modifiers must remain available")
        dual.remove(); try await Task.sleep(for: .seconds(0.46))
        precondition(singles == 0, "Double modifiers must cancel both pending single actions")
        print("PASS: ordinary and prompt double shortcuts coexist with single recording actions")
        print("PASS: synthetic Control double-start / delayed single-send / double-paste in both monitor orders; opening release, chord interruption, cooldown, capture suppression, timeout, all modifiers, duplicate/permission rejection and teardown. AX trust injected for fixture; no physical keys or STT.")
    }
}
