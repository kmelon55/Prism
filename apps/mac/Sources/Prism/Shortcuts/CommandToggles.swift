import Foundation
import Observation
import PrismKit

/// Commands the user switched off in Settings → Commands, in `disabled-commands-v1.json`.
///
/// The Tauri app kept the same list as `disabledCommandIds` inside its localStorage preferences. A disabled
/// command disappears from palette results and its global hotkey stops running it; the Commands table still lists
/// it so it can be switched back on. Only built-in commands, system commands, window layouts and applications can be
/// disabled (Tauri's `canDisable`); Settings and Quit always stay available, and library entries are removed rather
/// than disabled.
@MainActor
@Observable
final class CommandToggles {
    /// Posted after the list changes, so the palette can drop or restore rows.
    static let didChangeNotification = Notification.Name("PrismCommandTogglesDidChange")

    private struct File: Codable {
        var version = 1
        var disabledCommandIds: [String]
    }

    /// The ID families Tauri's `isDisableableCommandId` accepted (`native:` apps are `app:` here).
    static let disableablePrefixes = ["prism:", "system:", "window:", "app:"]
    /// Single commands from feature modules that Tauri listed as built-in commands.
    static let disableableIDs: Set<String> = ["clipboard:open-history"]
    /// Tauri's `requiredBuiltInManagement` commands, plus the transient update row.
    static let requiredCommandIDs: Set<String> = ["prism:preferences", "prism:quit", "prism:update"]

    private(set) var disabled: Set<String> = []
    /// Set when the file exists but cannot be read; it is then never overwritten.
    private(set) var isUnreadable = false
    @ObservationIgnored private let store: JSONFileStore<File>

    init(paths: AppPaths) {
        store = JSONFileStore(url: paths.file("disabled-commands-v1.json"))
        reload()
    }

    func reload() {
        let exists = FileManager.default.fileExists(atPath: store.url.path)
        let file = store.load()
        isUnreadable = exists && (file == nil || file?.version != 1)
        disabled = isUnreadable ? [] : Set((file?.disabledCommandIds ?? []).filter { $0.count <= 512 && Self.canDisable($0) })
    }

    /// Tauri's `management.canDisable`: whether the Commands table offers a working switch for this ID.
    static func canDisable(_ commandID: String) -> Bool {
        guard !requiredCommandIDs.contains(commandID) else { return false }
        return disableableIDs.contains(commandID) || disableablePrefixes.contains { commandID.hasPrefix($0) }
    }

    func isEnabled(_ commandID: String) -> Bool {
        !disabled.contains(commandID)
    }

    func setEnabled(_ enabled: Bool, for commandID: String) {
        guard !isUnreadable, Self.canDisable(commandID), enabled != isEnabled(commandID) else { return }
        if enabled { disabled.remove(commandID) } else { disabled.insert(commandID) }
        try? store.save(File(disabledCommandIds: disabled.sorted()))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
