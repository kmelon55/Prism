import CoreGraphics
import Foundation

/// The active event tap that applies `KeyRemapEngine` to every key press.
///
/// It sits at the HID level, before macOS matches system and app shortcuts, so a held Space works for ⌘Tab and
/// ⌘Space too. The tap runs on its own thread: a busy main thread must never delay typing, and macOS disables a
/// tap whose callback is slow. Events Prism posts itself (its own remapped keys, paste, snippet expansion) pass
/// through untouched.
final class KeyboardEventTap: @unchecked Sendable {
    /// Marks events this tap posts.
    static let eventMarker: Int64 = 0x5052_534D_4B45_5953 // "PRSMKEYS"

    private let lock = NSLock()
    // Guarded by `lock`; written by the main thread, read by the tap thread.
    private var sharedRules = KeyEngineRules()
    private var sharedFrontmostApp: String?
    private var sharedRemapsPaused = false
    private var sharedVersion = 0

    // Tap thread only.
    private var engine = KeyRemapEngine()
    private var seenVersion = -1
    private var keyboardType: Int64 = 0
    private let source = CGEventSource(stateID: .privateState)
    private let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)

    // Guarded by `lock`; the tap thread re-enables a tap macOS turned off.
    private var tap: CFMachPort?
    // Main thread only.
    private var runLoop: CFRunLoop?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    init() {
        source?.userData = Self.eventMarker
    }

    func update(rules: KeyEngineRules) {
        withShared { $0.sharedRules = rules }
    }

    func setFrontmostApp(_ bundleID: String?) {
        withShared { $0.sharedFrontmostApp = bundleID }
    }

    func setRemapsPaused(_ paused: Bool) {
        withShared { $0.sharedRemapsPaused = paused }
    }

    private func withShared(_ change: (KeyboardEventTap) -> Void) {
        lock.lock()
        change(self)
        sharedVersion += 1
        lock.unlock()
    }

    /// Creates the tap and its thread. Fails without Accessibility permission.
    @MainActor
    func start() -> Bool {
        guard !isRunning else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        lock.lock()
        self.tap = tap
        lock.unlock()
        nonisolated(unsafe) let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var threadRunLoop: CFRunLoop?
        let thread = Thread {
            threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Prism keyboard remapping"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = threadRunLoop
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Removes the tap, releasing any modifier a held key was pressing.
    @MainActor
    func stop() {
        lock.lock()
        let tap = tap
        self.tap = nil
        lock.unlock()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoop {
            // Let the tap thread release held modifiers, then stop its run loop.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                post(engine.reset())
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }
        CFMachPortInvalidate(tap)
        runLoop = nil
    }

    // MARK: Tap thread

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            post(engine.reset())
            lock.lock()
            let tap = tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Both checks: re-handling a posted tap of Space would post it again forever.
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker
            || event.getIntegerValueField(.eventSourceUnixProcessID) == ownPID { return Unmanaged.passUnretained(event) }
        syncShared()
        guard let input = input(type: type, event: event) else { return Unmanaged.passUnretained(event) }
        if engine.rules.isEmpty && engine.isIdle { return Unmanaged.passUnretained(event) }
        let decision = engine.handle(input)
        post(decision.posts)
        guard let current = decision.current else { return nil }
        if current.keyCode != input.keyCode, input.kind == .keyDown || input.kind == .keyUp,
           let replacement = makeEvent(KeyOutput(kind: input.kind == .keyDown ? .keyDown : .keyUp, keyCode: current.keyCode, flags: current.flags)) {
            replacement.setIntegerValueField(.keyboardEventAutorepeat, value: input.isRepeat ? 1 : 0)
            return Unmanaged.passRetained(replacement)
        }
        if current.flags != input.flags { event.flags = current.flags }
        return Unmanaged.passUnretained(event)
    }

    private func syncShared() {
        lock.lock()
        defer { lock.unlock() }
        guard seenVersion != sharedVersion else { return }
        seenVersion = sharedVersion
        engine.rules = sharedRules
        engine.frontmostApp = sharedFrontmostApp
        engine.remapsPaused = sharedRemapsPaused
    }

    private func input(type: CGEventType, event: CGEvent) -> KeyInput? {
        // Event timestamps are not nanoseconds on every Mac; the callback runs as the event arrives anyway.
        let time = ProcessInfo.processInfo.systemUptime
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown, .keyUp:
            keyboardType = event.getIntegerValueField(.keyboardEventKeyboardType)
            return KeyInput(kind: type == .keyDown ? .keyDown : .keyUp, keyCode: keyCode, flags: event.flags,
                            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, time: time)
        case .flagsChanged:
            return KeyInput(kind: .flagsChanged, keyCode: keyCode, flags: event.flags, time: time)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            return KeyInput(kind: .mouse, keyCode: 0, flags: event.flags, time: time)
        default:
            return nil
        }
    }

    private func post(_ outputs: [KeyOutput]) {
        for output in outputs { makeEvent(output)?.post(tap: .cghidEventTap) }
    }

    private func makeEvent(_ output: KeyOutput) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: output.keyCode, keyDown: output.kind != .keyUp) else { return nil }
        if output.kind == .flagsChanged { event.type = .flagsChanged }
        event.flags = output.flags
        if keyboardType != 0 { event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType) }
        return event
    }
}
