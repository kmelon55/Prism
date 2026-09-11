// Whisp's double-tap detector and NSEvent monitoring adapted for all Prism commands.
// MIT; see LICENSE-Whisp.
import AppKit

typealias ModifierShortcutCallback = @convention(c) (UInt32) -> Void

@MainActor final class PrismModifierShortcuts {
    static let shared = PrismModifierShortcuts()
    static let flags: [NSEvent.ModifierFlags] = [.control, .option, .shift, .command]
    var onTrigger: ((UInt32) -> Void)?
    private let isTrusted: () -> Bool
    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) { self.isTrusted = isTrusted }
    private var enabled: Set<UInt32> = []
    private var detectors = Array(repeating: ModifierDoubleTapDetector(), count: 4)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var captures: [String: TimeInterval] = [:]
    private var blocked: Set<UInt32> = []
    private var recordingAllowed: Set<UInt32> = []
    private var ignoreUntil: TimeInterval = 0

    func register(_ kind: UInt32) -> Int32 {
        guard kind < 4 else { return 3 }
        guard isTrusted() else { return 1 }
        guard !enabled.contains(kind) else { return 2 }
        enabled.insert(kind); reset()
        if globalMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event); return event
            }
        }
        guard globalMonitor != nil, localMonitor != nil else { unregister(kind); return 3 }
        return 0
    }
    func unregister(_ kind: UInt32) {
        enabled.remove(kind); reset()
        if enabled.isEmpty {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        }
    }
    func capture(_ owner: String, active: Bool) {
        if active { captures[owner] = ProcessInfo.processInfo.systemUptime + 2 }
        else { captures.removeValue(forKey: owner) }
        reset()
    }
    func blockRecordingModifiers(_ kinds: Set<UInt32>, allowingPrimary: UInt32? = nil, allowingAdditional: Set<UInt32> = []) {
        if !blocked.isEmpty { ignoreUntil = ProcessInfo.processInfo.systemUptime + 0.42 }
        blocked = kinds; recordingAllowed = allowingAdditional.union(allowingPrimary.map { [$0] } ?? []); reset()
    }
    private func reset() { for i in detectors.indices { detectors[i].reset() } }
    func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        captures = captures.filter { $0.value > now }
        guard captures.isEmpty, now >= ignoreUntil else { reset(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let all: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        for kind in enabled.sorted() {
            if blocked.contains(kind), !recordingAllowed.contains(kind) { detectors[Int(kind)].reset(); continue }
            let target = Self.flags[Int(kind)]
            if detectors[Int(kind)].handle(
                modifierDown: flags.contains(target),
                hasOtherModifiers: !flags.intersection(all.subtracting(target)).isEmpty,
                isKeyDown: event.type != .flagsChanged || ![59, 62, 58, 61, 56, 60, 55, 54].contains(event.keyCode),
                timestamp: event.timestamp
            ) { onTrigger?(kind) }
        }
    }
}

private func onModifierMain<T>(_ work: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
}
@_cdecl("prism_modifier_shortcut_register")
func prismModifierShortcutRegister(_ kind: UInt32, _ callback: ModifierShortcutCallback?) -> Int32 {
    onModifierMain { PrismModifierShortcuts.shared.onTrigger = { callback?($0) }; return PrismModifierShortcuts.shared.register(kind) }
}
@_cdecl("prism_modifier_shortcut_unregister")
func prismModifierShortcutUnregister(_ kind: UInt32) {
    onModifierMain { PrismModifierShortcuts.shared.unregister(kind) }
}
@_cdecl("prism_modifier_shortcut_capture")
func prismModifierShortcutCapture(_ owner: UnsafePointer<CChar>, _ active: Bool) {
    let owner = String(cString: owner)
    onModifierMain { PrismModifierShortcuts.shared.capture(owner, active: active) }
}
