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

    func registerTransfers() {
        SyncTransfers.register(SyncTransfer(id: "shortcut.launcher", title: "Prism 실행 단축키", read: {
            try TransferCodec.encode(self.launcher.accelerator)
        }, validate: { data in
            let value = try JSONDecoder().decode(String.self, from: data)
            guard Shortcut(accelerator: value) != nil else { throw TransferError("단축키 형식이 올바르지 않아요.") }
        }, apply: { data, _ in
            guard !self.isPaused else { throw TransferError("단축키 입력을 마친 뒤 다시 가져오세요.") }
            let value = try JSONDecoder().decode(String.self, from: data)
            guard let shortcut = Shortcut(accelerator: value), !self.commands.values.contains(shortcut.accelerator) else { throw TransferError("다른 명령의 단축키와 겹쳐요.") }
            let previous = self.launcher
            self.launcher = shortcut; self.registerLauncher()
            do {
                guard self.launcherError == nil else { throw TransferError("macOS 또는 다른 앱에서 사용하는 단축키예요.") }
                try self.launcherStore.save(LauncherFile(accelerator: value))
            } catch { self.launcher = previous; self.registerLauncher(); throw error }
        }))
        SyncTransfers.register(SyncTransfer(id: "shortcut.commands", title: "명령별 단축키", read: {
            try TransferCodec.encode(self.commands)
        }, validate: { data in _ = try Self.decodeTransfer(data) }, apply: { data, replace in
            guard !self.isPaused else { throw TransferError("단축키 입력을 마친 뒤 다시 가져오세요.") }
            let incoming = try Self.decodeTransfer(data)
            let previous = self.commands
            let next = replace ? incoming : previous.merging(incoming) { _, new in new }
            guard Set(next.values).count == next.count, !next.values.contains(self.launcher.accelerator) else { throw TransferError("단축키가 중복돼요. 기존 단축키를 확인하세요.") }
            self.commands = next; self.registerCommands()
            do {
                guard self.failures.isEmpty else { throw TransferError("등록할 수 없는 단축키가 있어 기존 설정을 유지했어요.") }
                try self.commandsStore.save(CommandsFile(shortcuts: next))
            } catch { self.commands = previous; self.registerCommands(); throw error }
            NotificationCenter.default.post(name: CommandShortcuts.didChangeNotification, object: nil)
        }))
    }

    private static func decodeTransfer(_ data: Data) throws -> [String: String] {
        let values = try JSONDecoder().decode([String: String].self, from: data)
        guard values.count <= 1000, Set(values.values).count == values.count,
              values.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && (Shortcut(accelerator: $0.value) != nil || doubleTapValues.contains($0.value)) }) else { throw TransferError("단축키 설정 형식이 올바르지 않아요.") }
        return values
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
