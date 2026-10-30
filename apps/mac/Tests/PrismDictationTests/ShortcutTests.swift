import AppKit
import Testing
@testable import PrismDictation

/// Ports of the Rust shortcut label tests and `ModifierShortcutCheck.swift`. Synthetic events only; no keys are posted.
@MainActor
@Suite(.serialized)
struct ShortcutTests {
    @Test func startShortcutsParseAndFormatLikeTheTauriApp() {
        #expect(StartShortcut(stored: "DoubleControl") == .doubleModifier(.control))
        #expect(StartShortcut(stored: "doubleoption").doubleModifier == .option)
        #expect(StartShortcut(stored: "DoubleControl").label == "⌃ ⌃")
        #expect(StartShortcut(stored: "alt+KeyD").label == "⌥ D")
        #expect(StartShortcut(stored: "shift+super+Digit1").label == "⇧ ⌘ 1")
        #expect(StartShortcut.spacedLabel("Control+Alt+Space") == "⌃ ⌥ Space")
        if case .keys = StartShortcut(stored: "alt+KeyD") {} else { Issue.record("Expected a key combination") }
    }

    /// Port of the Rust `shortcuts_target_the_focused_input_instead_of_the_previous_app` test.
    @Test func shortcutsTargetTheFocusedInputAndTheLauncherTargetsThePreviousApp() {
        #expect(DictationService.fallbackPID(paletteVisible: false, prismActive: true, previousPID: 41, ownPID: 42) == 42)
        #expect(DictationService.fallbackPID(paletteVisible: false, prismActive: false, previousPID: 41, ownPID: 42) == 0)
        #expect(DictationService.fallbackPID(paletteVisible: true, prismActive: true, previousPID: 41, ownPID: 42) == 41)
        #expect(DictationService.fallbackPID(paletteVisible: true, prismActive: false, previousPID: 41, ownPID: 42) == 41)
        #expect(DictationService.fallbackPID(paletteVisible: true, prismActive: true, previousPID: 0, ownPID: 42) == 0)
    }

    @Test func readsDictationCommandsFromTheShellShortcutFile() throws {
        let folder = TemporaryDirectory()
        let file = CommandShortcutsFile(url: folder.url.appending(path: CommandShortcutsFile.fileName))
        #expect(file.load().dictation == nil)
        try Data(#"{"version":1,"shortcuts":{"prism:dictation":"DoubleControl","prism:dictation-prompt":"alt+KeyP","clipboard:open-history":"shift+super+KeyV"}}"#.utf8).write(to: file.url)
        let loaded = file.load()
        #expect(loaded.dictation == .doubleModifier(.control))
        #expect(loaded.prompt?.label == "⌥ P")
        try Data(#"{"version":2,"shortcuts":{"prism:dictation":"DoubleControl"}}"#.utf8).write(to: file.url)
        #expect(file.load().dictation == nil)
    }

    @Test func detectorNeedsTwoCleanTapsWithinTheInterval() {
        var detector = ModifierDoubleTapDetector()
        func feed(_ down: Bool, _ time: Double, key: Bool = false) -> Bool {
            detector.handle(modifierDown: down, hasOtherModifiers: false, isKeyDown: key, timestamp: time)
        }
        let first = feed(true, 0), release = feed(false, 0.1), second = feed(true, 0.3)
        #expect(!first && !release && second)
        detector.reset()
        _ = feed(true, 1); _ = feed(false, 1.1)
        let slow = feed(true, 1.6)
        #expect(!slow, "Too slow")
        _ = feed(false, 1.7); _ = feed(true, 1.8, key: true)
        let interrupted = feed(true, 1.9)
        #expect(!interrupted, "A key press interrupts")
    }

    private func flags(_ modifier: DoubleModifier, down: Bool, at time: Double, into monitor: ModifierShortcutMonitor, controls: RecordingControls? = nil,
                       controlsFirst: Bool = false) {
        let keyCode: UInt16 = [59, 58, 56, 55][Int(modifier.rawValue)]
        let value: NSEvent.ModifierFlags = down ? modifier.flag : []
        if controlsFirst { controls?.handleModifier(type: .flagsChanged, keyCode: keyCode, flags: value) }
        monitor.handle(type: .flagsChanged, keyCode: keyCode, flags: value, timestamp: time)
        if !controlsFirst { controls?.handleModifier(type: .flagsChanged, keyCode: keyCode, flags: value) }
    }

    @Test func registrationNeedsAccessibilityAndRejectsDuplicates() throws {
        let denied = ModifierShortcutMonitor(isTrusted: { false }, installMonitors: false)
        #expect(throws: ModifierShortcutMonitor.RegistrationError.accessibilityRequired) { try denied.register(.control) }
        let monitor = ModifierShortcutMonitor(isTrusted: { true }, installMonitors: false)
        try monitor.register(.control)
        #expect(throws: ModifierShortcutMonitor.RegistrationError.alreadyRegistered) { try monitor.register(.control) }
    }

    @Test func everyModifierCanBeDoubleTapped() throws {
        let monitor = ModifierShortcutMonitor(isTrusted: { true }, installMonitors: false)
        for modifier in DoubleModifier.allCases {
            try monitor.register(modifier)
            var fired: [DoubleModifier] = []
            monitor.onTrigger = { fired.append($0) }
            for (down, time) in [(true, 10.0), (false, 10.1), (true, 10.2), (false, 10.3)] { flags(modifier, down: down, at: time, into: monitor) }
            #expect(fired == [modifier])
            monitor.unregister(modifier)
        }
    }

    @Test func suspensionAndTimeoutSuppressTriggers() async throws {
        let monitor = ModifierShortcutMonitor(isTrusted: { true }, installMonitors: false)
        try monitor.register(.control)
        var starts = 0
        monitor.onTrigger = { _ in starts += 1 }
        monitor.setSuspended(true)
        for (down, time) in [(true, 3.0), (false, 3.1), (true, 3.2), (false, 3.3)] { flags(.control, down: down, at: time, into: monitor) }
        #expect(starts == 0, "Recording a shortcut must suppress its existing action")
        monitor.setSuspended(false)
        for (down, time) in [(true, 4.0), (false, 4.1), (true, 4.6), (false, 4.7)] { flags(.control, down: down, at: time, into: monitor) }
        #expect(starts == 0, "A tap after the 0.42-second limit must not trigger")
        flags(.control, down: true, at: 4.8, into: monitor)
        #expect(starts == 1)
    }

    /// Control double-tap starts, a single Control sends, and a second double tap pastes instead of sending.
    @Test func doubleStartSingleSendAndDoublePaste() async throws {
        _ = NSApplication.shared
        let monitor = ModifierShortcutMonitor(isTrusted: { true }, installMonitors: false)
        try monitor.register(.control)
        let controls = RecordingControls(modifierShortcuts: monitor, isTrusted: { true }, modifierFlags: { .control })
        controls.settings.cancel = RecordingShortcutSetting(mode: .disabled, keyCode: 53, modifiers: 0, label: "")
        controls.settings.send = .singleModifier(.singleControl)
        controls.settings.primaryDoubleModifier = .control
        var starts = 0, sends = 0, pastes = 0
        monitor.onTrigger = { _ in
            if controls.isRegistered(.send) {
                pastes += 1
                controls.remove()
            } else {
                starts += 1
                controls.install(recording: true)
            }
        }
        controls.onAction = { action in
            if action == .send { sends += 1; controls.remove() }
        }
        defer { controls.remove() }
        func tap(_ down: Bool, _ time: Double) { flags(.control, down: down, at: time, into: monitor, controls: controls) }
        tap(true, 0); tap(false, 0.1); tap(true, 0.3)
        #expect(starts == 1 && sends == 0 && controls.isRegistered(.send))
        tap(false, 0.4)
        #expect(sends == 0, "The opening chord's release must not send")
        tap(true, 1)
        monitor.handle(type: .keyDown, keyCode: 0, flags: .control, timestamp: 1.05)
        controls.handleModifier(type: .keyDown, keyCode: 0, flags: .control)
        tap(false, 1.1)
        #expect(sends == 0, "Control-A must not send")
        tap(true, 2); tap(false, 2.1)
        #expect(sends == 0, "A single Control waits for a possible second tap")
        try await Task.sleep(for: .seconds(0.5))
        #expect(sends == 1 && starts == 1 && !controls.isRegistered(.send))
        tap(true, 2.2); tap(false, 2.3)
        #expect(starts == 1, "Send must not arm a new double tap during the cooldown")
        try await Task.sleep(for: .seconds(0.45))

        for controlsFirst in [false, true] {
            controls.install(recording: true)
            controls.handleModifier(type: .flagsChanged, keyCode: 59, flags: []) // opening release
            func recordingTap(_ down: Bool, _ time: Double) {
                flags(.control, down: down, at: time, into: monitor, controls: controls, controlsFirst: controlsFirst)
            }
            recordingTap(true, 6); recordingTap(false, 6.1)
            try await Task.sleep(for: .seconds(0.1))
            #expect(sends == 1, "The first tap must not send")
            recordingTap(true, 6.25); recordingTap(false, 6.3)
            #expect(pastes == (controlsFirst ? 2 : 1) && sends == 1)
            try await Task.sleep(for: .seconds(0.5))
            #expect(sends == 1, "A double Control cancels the pending send")
            try await Task.sleep(for: .seconds(0.45))
        }

        controls.install(recording: true)
        controls.handleModifier(type: .flagsChanged, keyCode: 59, flags: [])
        tap(true, 7.1); tap(false, 7.2)
        controls.remove()
        try await Task.sleep(for: .seconds(0.5))
        #expect(sends == 1, "Teardown cancels the pending single tap")
    }

    @Test func ordinaryAndPromptDoubleTapsCoexistWithSingleActions() async throws {
        let monitor = ModifierShortcutMonitor(isTrusted: { true }, installMonitors: false)
        try monitor.register(.control)
        try monitor.register(.option)
        var kinds: [DoubleModifier] = []
        monitor.onTrigger = { kinds.append($0) }
        let controls = RecordingControls(modifierShortcuts: monitor, isTrusted: { true }, modifierFlags: { [] })
        controls.settings.primaryDoubleModifier = .control
        controls.settings.additionalDoubleModifiers = [.control, .option]
        controls.settings.cancel = RecordingShortcutSetting(mode: .disabled, keyCode: 53, modifiers: 0, label: "")
        controls.settings.copy = .singleModifier(.singleOption)
        controls.settings.send = .singleModifier(.singleControl)
        var singles = 0
        controls.onAction = { _ in singles += 1 }
        controls.install(recording: true)
        for modifier in [DoubleModifier.control, .option] {
            let offset = Double(modifier.rawValue)
            for (down, time) in [(true, 20.0), (false, 20.1), (true, 20.2)] {
                flags(modifier, down: down, at: time + offset, into: monitor, controls: controls, controlsFirst: true)
            }
        }
        #expect(kinds == [.control, .option])
        controls.remove()
        try await Task.sleep(for: .seconds(0.5))
        #expect(singles == 0)
    }

    @Test func singleModifierWithoutAccessibilityFailsRegistration() {
        let controls = RecordingControls(modifierShortcuts: nil, isTrusted: { false }, modifierFlags: { [] })
        controls.settings.cancel = RecordingShortcutSetting(mode: .disabled, keyCode: 53, modifiers: 0, label: "")
        controls.settings.send = .singleModifier(.singleShift)
        controls.install(recording: true)
        #expect(!controls.isRegistered(.send) && controls.failedActions == [.send])
        controls.remove()
        #expect(controls.failedActions.isEmpty)
    }
}
