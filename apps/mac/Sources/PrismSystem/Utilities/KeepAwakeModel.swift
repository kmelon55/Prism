import AppKit
import IOKit.pwr_mgt
import Observation

/// An assertion is owned by this process, never a detached caffeinate process or a persistent setting.
private final class PowerAssertion {
    private var id: IOPMAssertionID?

    func acquire() throws {
        guard id == nil else { return }
        var value = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Prism Keep Awake" as CFString, &value)
        guard status == kIOReturnSuccess else { throw UtilityError("Could not keep your Mac awake.", status: status) }
        id = value
    }

    func release() throws {
        guard let id else { return }
        let status = IOPMAssertionRelease(id)
        guard status == kIOReturnSuccess else { throw UtilityError("Could not stop Keep Awake. Try again.", status: status) }
        self.id = nil
    }

    deinit { if let id { IOPMAssertionRelease(id) } }
}

struct UtilityError: LocalizedError {
    let message: String
    let status: Int32?
    init(_ message: String, status: Int32? = nil) { self.message = message; self.status = status }
    var errorDescription: String? {
        SystemStrings.localized(message) + (status.map { " (\($0))" } ?? "")
    }
}

@MainActor @Observable
final class KeepAwakeModel {
    private(set) var deadline: Date?
    private(set) var error: String?
    @ObservationIgnored private let acquire: () throws -> Void
    @ObservationIgnored private let release: () throws -> Void
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(acquire: @escaping () throws -> Void, release: @escaping () throws -> Void) {
        self.acquire = acquire
        self.release = release
    }

    convenience init() {
        let assertion = PowerAssertion()
        self.init(acquire: { try assertion.acquire() }, release: { try assertion.release() })
    }

    var isActive: Bool { deadline != nil }

    @discardableResult func start(minutes: Int, now: Date = Date()) -> Bool {
        do {
            if !isActive { try acquire() }
            deadline = now.addingTimeInterval(TimeInterval(min(180, max(1, minutes)) * 60))
            error = nil
            schedule()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func stop() -> Bool {
        do {
            try release()
            deadline = nil
            timer?.invalidate(); timer = nil
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func refresh(now: Date = Date()) {
        if let deadline, now >= deadline { stop() }
    }

    func observeLifecycle() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let terminate = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        observers = [(workspace, wake), (.default, terminate)]
    }

    func shutdown() {
        stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

    private func schedule() {
        timer?.invalidate()
        guard let deadline else { timer = nil; return }
        let timer = Timer(timeInterval: max(0.1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
