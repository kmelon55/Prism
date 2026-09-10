// Recording settings and modifier handling reused from Whisp. MIT; see LICENSE-Whisp.
import Carbon.HIToolbox
import AppKit
struct RecordingOverlayHint: Identifiable { let id: String; let key: String; let label: String }
struct OverlaySettings: Decodable {
    var showRecordingShortcutHints: Bool? = true
    var showTranscriptionStatus: Bool? = true
    var primaryShortcutLabel: String? = nil
    var primaryDoubleModifier: UInt32? = nil
    var uiLanguage: String? = "ko"
    var defaultDelivery: String? = "paste"
    var recordingCopyShortcut: RecordingShortcutSetting?
    var recordingCancelShortcut: RecordingShortcutSetting?
    var recordingPasteShortcut: RecordingShortcutSetting?
    var recordingPasteAndEnterShortcut: RecordingShortcutSetting?
    func binding(_ id: UInt32) -> RecordingShortcutSetting {
        switch id {
        case 1: return recordingCancelShortcut ?? .cancelDefault
        case 4: return recordingCopyShortcut ?? RecordingShortcutSetting(mode: .disabled, keyCode: 0, modifiers: 0, label: "")
        case 3: return recordingPasteShortcut ?? .pasteDefault
        default: return recordingPasteAndEnterShortcut ?? .pasteAndEnterDefault
        }
    }
    func label(_ id: UInt32) -> String? {
        let binding = binding(id)
        switch binding.mode {
        case .disabled: return nil
        case .sameAsPrimary: return primaryShortcutLabel
        case .custom: guard !binding.label.isEmpty else { return nil }; return binding.kind.isSingleModifier ? ShortcutLabelFormatter.label(for: binding.kind) : ShortcutLabelFormatter.label(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
    }
}
@MainActor final class RecordingControls {
    var settings = OverlaySettings()
    private let modifierShortcuts: PrismModifierShortcuts
    private let isTrusted: () -> Bool
    private let modifierFlags: () -> NSEvent.ModifierFlags
    init(modifierShortcuts: PrismModifierShortcuts? = nil, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }, modifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) {
        self.modifierShortcuts = modifierShortcuts ?? .shared; self.isTrusted = isTrusted; self.modifierFlags = modifierFlags
    }
    private var handler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var activeIDs: Set<UInt32> = []
    private(set) var failedIDs: [UInt32] = []
    var onCancel: (() -> Void)?
    var onSend: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var cancelRegistered: Bool { activeIDs.contains(1) }
    var sendRegistered: Bool { activeIDs.contains(2) }
    func registered(_ id: UInt32) -> Bool { activeIDs.contains(id) }
    private var recordingModifierGlobalMonitor: Any?
    private var recordingModifierLocalMonitor: Any?
    private var recordingModifierActions: [RecordingShortcutKind: UInt32] = [:]
    private var heldAtInstallation: NSEvent.ModifierFlags = []
    private var activeRecordingModifier: RecordingShortcutKind?
    private var recordingModifierWasInterrupted = false
    private var pendingRecordingModifierTask: Task<Void, Never>?
    private func handleHotKey(_ id: UInt32) {
        guard activeIDs.contains(id) else { return }
        switch id { case 1: onCancel?(); case 2: onSend?(); case 3: onPaste?(); case 4: onCopy?(); default: break }
    }
    func install(recording: Bool) {
        remove()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x50524454 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let controls = Unmanaged<RecordingControls>.fromOpaque(pointer).takeUnretainedValue()
                guard controls.activeIDs.contains(identifier.id) else { return OSStatus(eventNotHandledErr) }
                controls.handleHotKey(identifier.id); return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for id: UInt32 in recording ? [1, 4, 3, 2] : [1] {
            let binding = settings.binding(id)
            guard binding.mode == .custom else { continue }
            guard settings.label(id) != nil else { failedIDs.append(id); continue }
            if binding.kind.isSingleModifier {
                guard isTrusted(), recordingModifierActions[binding.kind] == nil else { failedIDs.append(id); continue }
                recordingModifierActions[binding.kind] = id; activeIDs.insert(id)
            } else {
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x50524454, id: id), GetApplicationEventTarget(), 0, &reference)
                if status == noErr, handler != nil, let reference { references[id] = reference; activeIDs.insert(id) }
                else { if let reference { UnregisterEventHotKey(reference) }; failedIDs.append(id) }
            }
        }
        modifierShortcuts.blockRecordingModifiers(Set(recordingModifierActions.keys.compactMap { kind in
            switch kind { case .singleControl: return UInt32(0); case .singleOption: return UInt32(1); case .singleShift: return UInt32(2); case .singleCommand: return UInt32(3); case .keyCombination: return nil }
        }), allowingPrimary: recording ? settings.primaryDoubleModifier : nil)
        installRecordingModifierMonitorsIfNeeded()
    }
    func remove() {
        modifierShortcuts.blockRecordingModifiers([])
        for reference in references.values { UnregisterEventHotKey(reference) }; references.removeAll(); activeIDs.removeAll(); failedIDs.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let recordingModifierGlobalMonitor { NSEvent.removeMonitor(recordingModifierGlobalMonitor) }; recordingModifierGlobalMonitor = nil
        if let recordingModifierLocalMonitor { NSEvent.removeMonitor(recordingModifierLocalMonitor) }; recordingModifierLocalMonitor = nil
        pendingRecordingModifierTask?.cancel(); pendingRecordingModifierTask = nil
        recordingModifierActions.removeAll(); activeRecordingModifier = nil; recordingModifierWasInterrupted = false
    }
    private func installRecordingModifierMonitorsIfNeeded() {
        heldAtInstallation = modifierFlags().intersection([.control, .option, .shift, .command])
        guard !recordingModifierActions.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        recordingModifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            Task { @MainActor in self?.handleRecordingModifier(event) }
        }
        recordingModifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            self?.handleRecordingModifier(event)
            return event
        }
    }

    func handleRecordingModifier(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            if activeRecordingModifier != nil {
                recordingModifierWasInterrupted = true
            }
            pendingRecordingModifierTask?.cancel()
            pendingRecordingModifierTask = nil
            return
        }

        guard let kind = Self.recordingModifierKind(for: event.keyCode),
              let targetFlag = Self.modifierFlag(for: kind)
        else {
            if activeRecordingModifier != nil {
                recordingModifierWasInterrupted = true
            }
            return
        }

        if let activeRecordingModifier, activeRecordingModifier != kind {
            recordingModifierWasInterrupted = true
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let otherModifiers = flags.intersection(allModifiers.subtracting(targetFlag))
        let isPressed = flags.contains(targetFlag)
        // The second press that opened dictation is not a recording action.
        if heldAtInstallation.contains(targetFlag) {
            if !isPressed { heldAtInstallation.remove(targetFlag) }
            return
        }

        if isPressed {
            guard recordingModifierActions[kind] != nil else {
                if activeRecordingModifier != nil {
                    recordingModifierWasInterrupted = true
                }
                return
            }
            pendingRecordingModifierTask?.cancel()
            pendingRecordingModifierTask = nil
            activeRecordingModifier = kind
            recordingModifierWasInterrupted = !otherModifiers.isEmpty
            return
        }

        guard activeRecordingModifier == kind else { return }
        activeRecordingModifier = nil
        let wasInterrupted = recordingModifierWasInterrupted || !otherModifiers.isEmpty
        recordingModifierWasInterrupted = false
        guard !wasInterrupted, let identifier = recordingModifierActions[kind] else { return }

        // Match Whisp: give the primary double tap (0.42 s) priority over a
        // single release of the same modifier. A second press cancels this task.
        guard let primary = settings.primaryDoubleModifier, primary < 4,
              Self.modifierFlag(for: kind) == PrismModifierShortcuts.flags[Int(primary)] else {
            handleHotKey(identifier)
            return
        }
        pendingRecordingModifierTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.43)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pendingRecordingModifierTask = nil
            self?.handleHotKey(identifier)
        }
    }

    private static func modifierFlag(for kind: RecordingShortcutKind) -> NSEvent.ModifierFlags? {
        switch kind {
        case .singleControl: return .control
        case .singleOption: return .option
        case .singleShift: return .shift
        case .singleCommand: return .command
        case .keyCombination: return nil
        }
    }

    private static func recordingModifierKind(for keyCode: UInt16) -> RecordingShortcutKind? {
        switch keyCode {
        case 59, 62: return .singleControl
        case 58, 61: return .singleOption
        case 56, 60: return .singleShift
        case 55, 54: return .singleCommand
        default: return nil
        }
    }

}
