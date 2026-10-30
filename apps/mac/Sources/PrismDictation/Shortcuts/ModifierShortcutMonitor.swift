// Whisp's double-tap detector and NSEvent monitoring. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit

/// Watches for double-tapped modifiers (`DoubleControl` and friends). Global key monitoring needs Accessibility.
@MainActor
final class ModifierShortcutMonitor {
    enum RegistrationError: Error, Equatable {
        case accessibilityRequired, alreadyRegistered, monitorFailed
    }

    var onTrigger: ((DoubleModifier) -> Void)?
    private let isTrusted: () -> Bool
    private let installMonitors: Bool
    private var enabled: Set<DoubleModifier> = []
    private var detectors = Array(repeating: ModifierDoubleTapDetector(), count: 4)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var blocked: Set<DoubleModifier> = []
    private var recordingAllowed: Set<DoubleModifier> = []
    private var ignoreUntil: TimeInterval = 0
    private var suspended = false

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }, installMonitors: Bool = true) {
        self.isTrusted = isTrusted
        self.installMonitors = installMonitors
    }

    var registered: Set<DoubleModifier> { enabled }

    func register(_ modifier: DoubleModifier) throws(RegistrationError) {
        guard isTrusted() else { throw .accessibilityRequired }
        guard !enabled.contains(modifier) else { throw .alreadyRegistered }
        enabled.insert(modifier)
        reset()
        guard installMonitors else { return }
        if globalMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
        guard globalMonitor != nil, localMonitor != nil else {
            unregister(modifier)
            throw .monitorFailed
        }
    }

    func unregister(_ modifier: DoubleModifier) {
        enabled.remove(modifier)
        reset()
        if enabled.isEmpty {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
        }
    }

    func unregisterAll() {
        for modifier in enabled { unregister(modifier) }
    }

    /// Pauses detection while a settings recorder captures keys.
    func setSuspended(_ value: Bool) {
        suspended = value
        reset()
    }

    /// While recording, single-modifier actions on the same key win over its double tap, except for the start
    /// shortcuts that finish the recording. A short cooldown after unblocking keeps a send key from reopening.
    func blockRecordingModifiers(_ modifiers: Set<DoubleModifier>, allowing allowed: Set<DoubleModifier> = []) {
        if !blocked.isEmpty { ignoreUntil = ProcessInfo.processInfo.systemUptime + 0.42 }
        blocked = modifiers
        recordingAllowed = allowed
        reset()
    }

    func handle(_ event: NSEvent) {
        handle(type: event.type, keyCode: event.keyCodeIfKey, flags: event.modifierFlags, timestamp: event.timestamp)
    }

    func handle(type: NSEvent.EventType, keyCode: UInt16, flags rawFlags: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        guard !suspended, ProcessInfo.processInfo.systemUptime >= ignoreUntil else { reset(); return }
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let all: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let isModifierKey = type == .flagsChanged && RecordingShortcutKind.forKeyCode(keyCode) != nil
        for modifier in enabled.sorted(by: { $0.rawValue < $1.rawValue }) {
            let index = Int(modifier.rawValue)
            if blocked.contains(modifier), !recordingAllowed.contains(modifier) { detectors[index].reset(); continue }
            if detectors[index].handle(modifierDown: flags.contains(modifier.flag),
                                       hasOtherModifiers: !flags.intersection(all.subtracting(modifier.flag)).isEmpty,
                                       isKeyDown: !isModifierKey, timestamp: timestamp) {
                onTrigger?(modifier)
            }
        }
    }

    private func reset() {
        for index in detectors.indices { detectors[index].reset() }
    }
}

extension NSEvent {
    /// The key code, or 0 for mouse events. Reading `keyCode` from a mouse event raises an Objective-C exception,
    /// and inside a local monitor that silently drops the click.
    var keyCodeIfKey: UInt16 {
        [.keyDown, .keyUp, .flagsChanged].contains(type) ? keyCode : 0
    }
}
