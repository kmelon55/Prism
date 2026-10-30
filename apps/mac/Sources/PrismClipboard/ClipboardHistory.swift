import AppKit
import PrismKit

/// Owns the store and monitor and runs history actions. Store work happens off the main actor; views
/// observe `didChange` to refresh after captures and edits.
@MainActor
public final class ClipboardHistory {
    public static let didChange = Notification.Name("dev.prism.clipboard.didChange")

    public let store: ClipboardStore
    weak var context: (any PrismContext)?
    private let frontmost = FrontmostApplication()
    private lazy var monitor = ClipboardMonitor(store: store, frontmost: frontmost) {
        Task { @MainActor in NotificationCenter.default.post(name: ClipboardHistory.didChange, object: nil) }
    }
    private var isPasting = false

    public init(store: ClipboardStore, context: (any PrismContext)?) {
        self.store = store
        self.context = context
    }

    public func start() {
        frontmost.start()
        monitor.update()
    }

    /// Runs a store call on a background thread, then refreshes the monitor and open views.
    func perform<T: Sendable>(_ body: @escaping @Sendable (ClipboardStore) throws(ClipboardError) -> T) async throws(ClipboardError) -> T {
        let store = store
        let result = await Task.detached(priority: .userInitiated) { () -> Result<T, ClipboardError> in
            Result { () throws(ClipboardError) in try body(store) }
        }.value
        monitor.update()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return try result.get()
    }

    /// A read that does not notify observers.
    func read<T: Sendable>(_ body: @escaping @Sendable (ClipboardStore) throws(ClipboardError) -> T) async throws(ClipboardError) -> T {
        let store = store
        return try await Task.detached(priority: .userInitiated) { () -> Result<T, ClipboardError> in
            Result { () throws(ClipboardError) in try body(store) }
        }.value.get()
    }

    public func settings() async -> ClipboardSettingsState {
        let store = store
        return await Task.detached(priority: .userInitiated) { store.settings() }.value
    }

    /// Copies the stored original to the system clipboard.
    public func copy(id: Int64) async throws(ClipboardError) {
        let payload = try await read { store throws(ClipboardError) in try store.prepareForAction(id: id) }
        try PasteboardIO.write(payload, to: .general)
    }

    /// Pastes into the app that was frontmost before the palette opened. Fails closed: Accessibility, the
    /// target, and the clipboard revision are checked again right before ⌘V, and nothing is ever typed into
    /// a different app. The palette must still be visible; it is hidden once the entry is on the clipboard.
    public func paste(id: Int64) async -> PaletteActionOutcome {
        guard !isPasting else { return .notify(ClipboardText.localize("A paste is already in progress.")) }
        isPasting = true
        defer { isPasting = false }

        guard Permissions.isAccessibilityTrusted else {
            Permissions.requestAccessibility()
            return .notify(ClipboardText.localize("Paste needs Accessibility permission. Allow it in Settings or use Copy."))
        }
        guard let target = context?.previousApplication, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return .notify(ClipboardText.localize("The paste target changed or is missing. Reopen Prism from the target window or use Copy."))
        }
        let revision: Int
        do {
            let payload = try await read { store throws(ClipboardError) in try store.prepareForAction(id: id) }
            revision = try PasteboardIO.write(payload, to: .general)
        } catch {
            return .notify(error.localizedDescription)
        }
        context?.hidePalette()
        let pid = target.processIdentifier
        if !target.isActive && !target.activate() {
            return fail("Could not activate the target app. The item was copied to the clipboard.")
        }
        // Activation is asynchronous. Never type into an unrelated foreground app.
        var activated = false
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(40))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                activated = true
                break
            }
        }
        guard activated else { return fail("Could not return to the target app. The item was copied to the clipboard.") }
        let result = Self.pasteIfRevisionMatches(revision, current: { NSPasteboard.general.changeCount }) {
            Self.postPaste(to: pid)
        }
        if case .failure(let error) = result { return fail(error.message) }
        return .dismiss
    }

    private func fail(_ message: String) -> PaletteActionOutcome {
        context?.showHUD(ClipboardText.localize(message))
        return .dismiss
    }

    /// Reads the revision once, immediately before posting. Never retries and never restores over another
    /// clipboard owner.
    nonisolated static func pasteIfRevisionMatches(
        _ expected: Int, current: () -> Int, post: () -> Result<Void, ClipboardError>
    ) -> Result<Void, ClipboardError> {
        guard current() == expected else {
            return .failure(ClipboardError("The clipboard changed, so paste was cancelled. Select the entry again."))
        }
        return post()
    }

    private static func postPaste(to pid: pid_t) -> Result<Void, ClipboardError> {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .failure(ClipboardError("Could not create the paste keystroke. The item was copied.")) }
        for event in [down, up] {
            event.flags = .maskCommand
            event.postToPid(pid)
        }
        return .success(())
    }
}
