import AppKit

/// The frontmost app's bundle identifier, kept current from workspace notifications so the monitor can
/// read it off the main thread.
final class FrontmostApplication: @unchecked Sendable {
    private let lock = NSLock()
    private var bundleIdentifier: String?
    private var observer: NSObjectProtocol?

    var current: String? { lock.withLock { bundleIdentifier } }

    @MainActor
    func start() {
        guard observer == nil else { return }
        set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(application?.bundleIdentifier)
        }
    }

    private func set(_ value: String?) {
        lock.withLock { bundleIdentifier = value }
    }
}

/// Polls `NSPasteboard.changeCount` on a utility queue. The timer has generous leeway so the system can
/// coalesce wakeups, and it only runs while history is enabled. Content is read only after the revision
/// changes.
final class ClipboardMonitor: @unchecked Sendable {
    private static let interval: DispatchTimeInterval = .milliseconds(650)
    /// About once a minute, expired unpinned entries are removed from disk.
    private static let pruneTicks = 90

    private let store: ClipboardStore
    private let frontmost: FrontmostApplication
    private let onCapture: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.prism.clipboard.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cursor = CaptureCursor()
    private var ticks = 0

    init(store: ClipboardStore, frontmost: FrontmostApplication, onCapture: @escaping @Sendable () -> Void) {
        self.store = store
        self.frontmost = frontmost
        self.onCapture = onCapture
    }

    /// Starts or stops polling to match the stored consent.
    func update() {
        queue.async { [self] in
            if store.isEnabled { resume() } else { suspend() }
        }
    }

    private func resume() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func suspend() {
        timer?.cancel()
        timer = nil
        cursor.pause()
    }

    private func tick() {
        guard let state = store.captureState() else {
            cursor.pause()
            if !store.isEnabled { suspend() }
            return
        }
        let observation = autoreleasepool {
            PasteboardIO.observe(.general, previous: cursor.previous(for: state.generation), preferences: state.preferences) {
                frontmost.current
            }
        }
        if let observation, cursor.observe(generation: state.generation, revision: observation.revision) {
            store.recordCapture(observation.result, generation: state.generation)
            onCapture()
        }
        ticks += 1
        if ticks >= Self.pruneTicks {
            ticks = 0
            if !store.hasPersistenceError { try? store.prune(at: ClipboardClock.nowMs()) }
        }
    }
}
