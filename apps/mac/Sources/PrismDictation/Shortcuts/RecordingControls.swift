// Scoped recording keys and single-modifier handling reused from Whisp. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit
import Carbon.HIToolbox

/// What the recording keys need from the settings and the start shortcuts.
struct RecordingControlSettings: Equatable {
    var cancel = RecordingShortcutSetting.cancelDefault
    var copy = RecordingShortcutSetting.copyDefault
    var paste = RecordingShortcutSetting.pasteDefault
    var send = RecordingShortcutSetting.pasteAndEnterDefault
    var defaultDelivery = DefaultDelivery.paste
    /// Label of the shortcut that started this session; paste's "same as start" shows it.
    var primaryLabel: String?
    var primaryDoubleModifier: DoubleModifier?
    /// Other start shortcuts that also finish a recording (the prompt shortcut while prompt mode is on).
    var additionalDoubleModifiers: Set<DoubleModifier> = []

    init() {}

    init(settings: DictationSettings, primary: StartShortcut?, additional: [StartShortcut?] = []) {
        cancel = settings.recordingCancelShortcut
        copy = settings.recordingCopyShortcut
        paste = settings.recordingPasteShortcut
        send = settings.recordingPasteAndEnterShortcut
        defaultDelivery = settings.defaultDelivery
        primaryLabel = primary?.label
        primaryDoubleModifier = primary?.doubleModifier
        additionalDoubleModifiers = Set(additional.compactMap { $0?.doubleModifier })
    }

    func binding(_ action: RecordingAction) -> RecordingShortcutSetting {
        switch action {
        case .cancel: cancel
        case .copy: copy
        case .paste: paste
        case .send: send
        }
    }

    func label(_ action: RecordingAction) -> String? { binding(action).displayLabel(primary: primaryLabel) }
}

/// Registers the cancel/copy/paste/send keys only while a recording is active, so they never swallow the same
/// keys in other apps. Carbon hot keys need no permission; single-modifier keys need Accessibility.
@MainActor
final class RecordingControls {
    private static let signature: OSType = 0x5052_4454 // "PRDT"

    var settings = RecordingControlSettings()
    var onAction: ((RecordingAction) -> Void)?
    private let modifierShortcuts: ModifierShortcutMonitor?
    private let isTrusted: () -> Bool
    private let modifierFlags: () -> NSEvent.ModifierFlags
    private var handler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var activeActions: Set<RecordingAction> = []
    private(set) var failedActions: [RecordingAction] = []
    private var modifierGlobalMonitor: Any?
    private var modifierLocalMonitor: Any?
    private var modifierActions: [RecordingShortcutKind: RecordingAction] = [:]
    private var heldAtInstallation: NSEvent.ModifierFlags = []
    private var activeModifier: RecordingShortcutKind?
    private var modifierInterrupted = false
    private var pendingModifierTask: Task<Void, Never>?

    init(modifierShortcuts: ModifierShortcutMonitor?, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         modifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) {
        self.modifierShortcuts = modifierShortcuts
        self.isTrusted = isTrusted
        self.modifierFlags = modifierFlags
    }

    func isRegistered(_ action: RecordingAction) -> Bool { activeActions.contains(action) }

    /// While recording every action is active; while transcribing only cancel remains.
    func install(recording: Bool) {
        remove()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == RecordingControls.signature else { return OSStatus(eventNotHandledErr) }
            let id = identifier.id
            return MainActor.assumeIsolated {
                let controls = Unmanaged<RecordingControls>.fromOpaque(pointer).takeUnretainedValue()
                guard let action = RecordingAction.allCases.first(where: { $0.hotKeyID == id }),
                      controls.activeActions.contains(action) else { return OSStatus(eventNotHandledErr) }
                controls.perform(action)
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)

        for action in recording ? RecordingAction.hintOrder : [.cancel] {
            let binding = settings.binding(action)
            guard binding.mode == .custom else { continue }
            guard settings.label(action) != nil else { failedActions.append(action); continue }
            if binding.kind.isSingleModifier {
                guard isTrusted(), modifierActions[binding.kind] == nil else { failedActions.append(action); continue }
                modifierActions[binding.kind] = action
                activeActions.insert(action)
            } else {
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: action.hotKeyID),
                                                 GetApplicationEventTarget(), 0, &reference)
                if status == noErr, handler != nil, let reference {
                    references[action.hotKeyID] = reference
                    activeActions.insert(action)
                } else {
                    if let reference { UnregisterEventHotKey(reference) }
                    failedActions.append(action)
                }
            }
        }
        var allowed: Set<DoubleModifier> = []
        if recording {
            allowed = settings.additionalDoubleModifiers
            if let primary = settings.primaryDoubleModifier { allowed.insert(primary) }
        }
        modifierShortcuts?.blockRecordingModifiers(Set(modifierActions.keys.compactMap(\.doubleModifier)), allowing: allowed)
        installModifierMonitorsIfNeeded()
    }

    func remove() {
        modifierShortcuts?.blockRecordingModifiers([])
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        activeActions.removeAll()
        failedActions.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if let modifierGlobalMonitor { NSEvent.removeMonitor(modifierGlobalMonitor) }
        if let modifierLocalMonitor { NSEvent.removeMonitor(modifierLocalMonitor) }
        modifierGlobalMonitor = nil
        modifierLocalMonitor = nil
        pendingModifierTask?.cancel()
        pendingModifierTask = nil
        modifierActions.removeAll()
        activeModifier = nil
        modifierInterrupted = false
    }

    private func perform(_ action: RecordingAction) {
        guard activeActions.contains(action) else { return }
        onAction?(action)
    }

    private func installModifierMonitorsIfNeeded() {
        heldAtInstallation = modifierFlags().intersection([.control, .option, .shift, .command])
        guard !modifierActions.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleModifier(type: event.type, keyCode: event.keyCodeIfKey, flags: event.modifierFlags) }
        }
        modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleModifier(type: event.type, keyCode: event.keyCodeIfKey, flags: event.modifierFlags)
            return event
        }
    }

    /// A single modifier fires on a clean release. Any other key or modifier in between cancels it.
    func handleModifier(type: NSEvent.EventType, keyCode: UInt16, flags rawFlags: NSEvent.ModifierFlags) {
        guard type == .flagsChanged else {
            if activeModifier != nil { modifierInterrupted = true }
            pendingModifierTask?.cancel()
            pendingModifierTask = nil
            return
        }
        guard let kind = RecordingShortcutKind.forKeyCode(keyCode), let targetFlag = kind.modifierFlag else {
            if activeModifier != nil { modifierInterrupted = true }
            return
        }
        if let activeModifier, activeModifier != kind {
            modifierInterrupted = true
            return
        }
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let allModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let otherModifiers = flags.intersection(allModifiers.subtracting(targetFlag))
        let isPressed = flags.contains(targetFlag)
        // The second press that opened dictation is not a recording action.
        if heldAtInstallation.contains(targetFlag) {
            if !isPressed { heldAtInstallation.remove(targetFlag) }
            return
        }
        if isPressed {
            guard modifierActions[kind] != nil else {
                if activeModifier != nil { modifierInterrupted = true }
                return
            }
            pendingModifierTask?.cancel()
            pendingModifierTask = nil
            activeModifier = kind
            modifierInterrupted = !otherModifiers.isEmpty
            return
        }
        guard activeModifier == kind else { return }
        activeModifier = nil
        let interrupted = modifierInterrupted || !otherModifiers.isEmpty
        modifierInterrupted = false
        guard !interrupted, let action = modifierActions[kind] else { return }
        // Give a start shortcut's double tap (0.42 s) on the same key priority over a single release.
        var doubles = settings.additionalDoubleModifiers
        if let primary = settings.primaryDoubleModifier { doubles.insert(primary) }
        guard let double = kind.doubleModifier, doubles.contains(double) else {
            perform(action)
            return
        }
        pendingModifierTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.43)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pendingModifierTask = nil
            self?.perform(action)
        }
    }
}
