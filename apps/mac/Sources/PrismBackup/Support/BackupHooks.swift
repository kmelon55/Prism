import Foundation
import PrismKit

/// How the shell lets an import change hotkeys through its own registrar, so a key another app holds is reported
/// per row (as the Tauri importer does) and the shell's in-memory shortcuts stay current.
public struct BackupShortcutAccess {
    /// The launcher accelerator and every command accelerator, in the shell's stored form.
    public var read: @MainActor () -> (launcher: String, commands: [String: String])
    /// Throws when the shortcut cannot be registered; the previous one must stay in effect.
    public var setLauncher: @MainActor (Shortcut) throws -> Void
    /// `nil` removes the command's hotkey. Throws when the shortcut cannot be registered.
    public var setCommand: @MainActor (String, Shortcut?) throws -> Void

    public init(read: @escaping @MainActor () -> (launcher: String, commands: [String: String]),
                setLauncher: @escaping @MainActor (Shortcut) throws -> Void,
                setCommand: @escaping @MainActor (String, Shortcut?) throws -> Void) {
        self.read = read
        self.setLauncher = setLauncher
        self.setCommand = setCommand
    }

    public struct RegistrationError: LocalizedError {
        public init() {}
        public var errorDescription: String? { "Used by another app" }
    }
}

/// The stores a restore or Raycast import changed, sent with `BackupFeature.dataDidChangeNotification`.
public enum BackupDataChange: String, Sendable {
    /// `library-v1.sqlite3` entries or favorites: Library should reload its cache and snippet expansion.
    case library
    /// `command-shortcuts-v1.json` or `global-shortcut-v1.json`, written directly because no
    /// `BackupShortcutAccess` was installed: the shell should reload and re-register them.
    case shortcuts
    /// `command-aliases-v1.json`.
    case aliases
    /// The `theme` and `showApplicationIcons` defaults: the shell should apply the theme.
    case appearance
}

/// Shortcut files written directly, for when the shell has not installed `BackupShortcutAccess`.
struct ShortcutFiles {
    let commandsURL: URL
    let launcherURL: URL

    func read() throws -> (launcher: String, commands: [String: String]) {
        let commands: [String: String]
        if let data = try? Data(contentsOf: commandsURL) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let shortcuts = object["shortcuts"] as? [String: String]
            else { throw BackupError("Saved shortcuts could not be read. They were left unchanged.") }
            commands = shortcuts
        } else {
            commands = [:]
        }
        let launcher = (try? Data(contentsOf: launcherURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["accelerator"] as? String } ?? Shortcut.launcherDefault.accelerator
        return (launcher, commands)
    }

    func setLauncher(_ shortcut: Shortcut) throws {
        try write(["version": 1, "accelerator": shortcut.accelerator], to: launcherURL)
    }

    func setCommand(_ commandID: String, _ shortcut: Shortcut?) throws {
        var commands = try read().commands
        commands[commandID] = shortcut?.accelerator
        try write(["version": 1, "shortcuts": commands], to: commandsURL)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupFiles.write(data, to: url, writeError: "Could not save shortcuts.")
    }
}

/// The real stores behind a Raycast import.
@MainActor
final class NativeImportTargets: RaycastImportTargets {
    let library: BackupLibrary
    let aliasStore: CommandAliasStore
    let files: ShortcutFiles
    let access: () -> BackupShortcutAccess?
    private(set) var changes: Set<BackupDataChange> = []

    init(library: BackupLibrary, aliasStore: CommandAliasStore, files: ShortcutFiles, access: @escaping () -> BackupShortcutAccess?) {
        self.library = library
        self.aliasStore = aliasStore
        self.files = files
        self.access = access
    }

    func takeChanges() -> Set<BackupDataChange> {
        defer { changes = [] }
        return changes
    }

    func hotkeys() throws -> [String: String] {
        let current = try access()?.read() ?? files.read()
        var hotkeys = current.commands
        hotkeys[RaycastPlan.launcherID] = current.launcher
        return hotkeys
    }

    func setHotkey(_ value: String?, for commandID: String) throws {
        let shortcut = try value.map { value in
            guard let shortcut = RaycastPlan.shortcut(value) else { throw BackupError("Unsupported shortcut") }
            return shortcut
        }
        if commandID == RaycastPlan.launcherID {
            guard let shortcut else { throw BackupError("Original launcher shortcut is missing") }
            if let access = access() { try access.setLauncher(shortcut) } else { try files.setLauncher(shortcut); changes.insert(.shortcuts) }
        } else if let access = access() {
            try access.setCommand(commandID, shortcut)
        } else {
            try files.setCommand(commandID, shortcut)
            changes.insert(.shortcuts)
        }
    }

    func aliases() throws -> [String: String] { try aliasStore.load() }

    func setAliases(_ aliases: [String: String]) throws {
        try aliasStore.save(aliases)
        changes.insert(.aliases)
    }

    /// The native app has no disabled commands yet.
    func disabled() -> Set<String> { [] }

    func libraryEntries() throws -> [ImportEntry] {
        try library.read().entries.map { ImportEntry(id: $0.id, kind: $0.kind, title: $0.title, value: $0.value, keyword: $0.keyword) }
    }

    func favoriteIDs() throws -> Set<String> { Set(try library.read().favorites.map(\.id)) }

    func saveEntry(_ entry: ImportEntry) throws {
        do {
            try library.database.transaction { try library.save(entry.backupEntry) }
        } catch is LibraryRules.Invalid {
            throw BackupError("Invalid or oversized item")
        }
        changes.insert(.library)
    }

    func deleteEntry(id: String) throws {
        try library.delete(id: id)
        changes.insert(.library)
    }
}
