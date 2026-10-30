import AppKit
import Observation
import PrismKit

/// Owns every global hotkey: the launcher (`global-shortcut-v1.json`) and per-command hotkeys
/// (`command-shortcuts-v1.json`), both in the Tauri app's format so saved shortcuts carry over.
/// Entries this shell cannot register, such as dictation's `DoubleControl`, are kept untouched.
@MainActor
@Observable
final class CommandHotKeys {
    private struct LauncherFile: Codable {
        var version = 1
        var accelerator: String
    }

    private struct CommandsFile: Codable {
        var version = 1
        var shortcuts: [String: String]
    }

    private(set) var launcher: Shortcut
    private(set) var launcherError: String?
    /// Raw accelerators by command ID, including entries owned by features.
    private(set) var commands: [String: String] = [:]
    private(set) var failures: Set<String> = []

    @ObservationIgnored private let launcherStore: JSONFileStore<LauncherFile>
    @ObservationIgnored private let commandsStore: JSONFileStore<CommandsFile>
    @ObservationIgnored private let onLauncher: () -> Void
    @ObservationIgnored private let onCommand: (String) -> Void
    @ObservationIgnored private var launcherHotKey: GlobalHotKey?
    @ObservationIgnored private var commandHotKeys: [String: GlobalHotKey] = [:]
    @ObservationIgnored private var isPaused = false

    init(paths: AppPaths, onLauncher: @escaping () -> Void, onCommand: @escaping (String) -> Void) {
        launcherStore = JSONFileStore(url: paths.file("global-shortcut-v1.json"))
        commandsStore = JSONFileStore(url: paths.file("command-shortcuts-v1.json"))
        self.onLauncher = onLauncher
        self.onCommand = onCommand
        launcher = launcherStore.load().flatMap { Shortcut(accelerator: $0.accelerator) } ?? .launcherDefault
        commands = commandsStore.load()?.shortcuts ?? [:]
    }

    func start() {
        registerLauncher()
        registerCommands()
        ShortcutRecording.onRecordingChanged = { [weak self] recording in self?.setPaused(recording) }
    }

    func shortcut(for commandID: String) -> Shortcut? {
        commands[commandID].flatMap(Shortcut.init(accelerator:))
    }

    /// Who already uses this shortcut, so the settings can explain a conflict.
    func owner(of shortcut: Shortcut) -> String? {
        if shortcut == launcher { return "launcher" }
        return commands.first { Shortcut(accelerator: $0.value) == shortcut }?.key
    }

    /// Keeps the previous launcher shortcut when the new one cannot be registered.
    func setLauncher(_ shortcut: Shortcut) {
        let previous = launcher
        launcher = shortcut
        registerLauncher()
        if launcherHotKey == nil {
            launcher = previous
            registerLauncher()
            launcherError = String(localized: "\(shortcut.displayName) is used by another app", bundle: .module)
            return
        }
        try? launcherStore.save(LauncherFile(accelerator: shortcut.accelerator))
    }

    func setShortcut(_ shortcut: Shortcut?, for commandID: String) {
        if let shortcut {
            // One shortcut runs one command.
            for (id, accelerator) in commands where id != commandID && Shortcut(accelerator: accelerator) == shortcut {
                commands[id] = nil
            }
            commands[commandID] = shortcut.accelerator
        } else {
            commands[commandID] = nil
        }
        try? commandsStore.save(CommandsFile(shortcuts: commands))
        NotificationCenter.default.post(name: CommandShortcuts.didChangeNotification, object: nil)
        registerCommands()
    }

    /// Modifier double-taps handled by the dictation module rather than registered here.
    static let doubleTapValues = ["DoubleControl", "DoubleOption", "DoubleShift", "DoubleCommand"]

    func setDoubleTap(_ value: String, for commandID: String) {
        for (id, existing) in commands where id != commandID && existing == value { commands[id] = nil }
        commands[commandID] = value
        try? commandsStore.save(CommandsFile(shortcuts: commands))
        NotificationCenter.default.post(name: CommandShortcuts.didChangeNotification, object: nil)
        registerCommands()
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            launcherHotKey = nil
            commandHotKeys = [:]
        } else {
            registerLauncher()
            registerCommands()
        }
    }

    private func registerLauncher() {
        launcherHotKey = nil
        guard !isPaused else { return }
        do {
            launcherHotKey = try GlobalHotKey(shortcut: launcher) { [weak self] in self?.onLauncher() }
            launcherError = launcher.isUsedBySystem
                ? String(localized: "macOS already uses \(launcher.displayName) (Keyboard Shortcuts in System Settings)", bundle: .module)
                : nil
        } catch {
            launcherError = String(localized: "\(launcher.displayName) is used by another app", bundle: .module)
        }
    }

    private func registerCommands() {
        commandHotKeys = [:]
        failures = []
        guard !isPaused else { return }
        for (id, accelerator) in commands {
            guard let shortcut = Shortcut(accelerator: accelerator) else { continue }
            do {
                commandHotKeys[id] = try GlobalHotKey(shortcut: shortcut) { [weak self] in self?.onCommand(id) }
                if shortcut.isUsedBySystem { failures.insert(id) }
            } catch {
                failures.insert(id)
            }
        }
    }
}
