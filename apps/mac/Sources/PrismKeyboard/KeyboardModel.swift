import AppKit
import ApplicationServices
import Observation
import PrismKit

/// Keeps the saved keyboard settings, and the event tap and Caps Lock mapping in step with them.
/// Nothing is installed while remapping is off or has no rules.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var config = KeyboardConfig()
    private(set) var isActive = false
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var lastError: String?

    @ObservationIgnored private let store: JSONFileStore<KeyboardConfig>
    @ObservationIgnored private let tap = KeyboardEventTap()
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var capsLockMapped: Bool?
    @ObservationIgnored private let mappingQueue = DispatchQueue(label: "Prism Caps Lock mapping")

    init(configURL: URL) {
        store = JSONFileStore(url: configURL)
        if FileManager.default.fileExists(atPath: configURL.path) {
            if let loaded = store.load() {
                config = loaded
            } else {
                lastError = String(localized: "Could not read keyboard settings. Remapping is off.", bundle: .module.prismLocalized)
            }
        }
        // Without a Caps Lock rule there is nothing to clean up at launch, so `hidutil` is not run.
        if !config.needsCapsLockMapping { capsLockMapped = false }
    }

    /// Called from `FeatureContribution.start`.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.tap.setFrontmostApp(bundleID) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })
        tap.setFrontmostApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        update()
    }

    func change(_ mutate: (inout KeyboardConfig) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        do {
            try store.save(next)
            lastError = nil
        } catch {
            lastError = String(localized: "Settings could not be saved.", bundle: .module.prismLocalized)
        }
        config = next
        if next.enabled && !AXIsProcessTrusted() { _ = Permissions.requestAccessibility() }
        update()
    }

    /// Keeps shortcut remaps off while a recorder on the Keyboard page listens.
    func setRecording(_ recording: Bool) {
        tap.setRemapsPaused(recording)
    }

    func refreshPermission() {
        accessibilityGranted = AXIsProcessTrusted()
        update()
    }

    /// Installs or removes the tap to match the settings and permission. While on but missing permission,
    /// checks again every two seconds.
    func update() {
        accessibilityGranted = AXIsProcessTrusted()
        let rules = config.engineRules
        tap.update(rules: rules)
        let wanted = config.enabled && !rules.isEmpty
        if wanted && accessibilityGranted && !tap.isRunning {
            if !tap.start() { lastError = String(localized: "Keyboard remapping could not start. Review permissions and retry.", bundle: .module.prismLocalized) }
        }
        if !(wanted && accessibilityGranted) && tap.isRunning { tap.stop() }
        isActive = tap.isRunning
        setCapsLockMapping(isActive && config.needsCapsLockMapping)
        if wanted && !accessibilityGranted {
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                }
            }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    private func shutdown() {
        tap.stop()
        isActive = false
        // Wait for the mapping to be removed: the process is about to exit.
        if capsLockMapped != false { mappingQueue.sync { CapsLockMapping.apply(false) } }
    }

    /// Applies the Caps Lock mapping when it should change, and once at launch to clean up after a crash.
    private func setCapsLockMapping(_ wanted: Bool) {
        guard capsLockMapped != wanted else { return }
        capsLockMapped = wanted
        mappingQueue.async { CapsLockMapping.apply(wanted) }
    }
}
