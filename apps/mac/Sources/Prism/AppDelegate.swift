import AppKit
import PrismBackup
import PrismClipboard
import PrismKit
import PrismLibrary
import PrismUpdates

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PrismContext {
    let paths = AppPaths.current()
    private let palette = PaletteController()
    private let settings = SettingsWindowController()
    private let applications = ApplicationsProvider()
    private let hud = HUD()
    private var statusItem: NSStatusItem?
    private lazy var aliases = CommandAliases(paths: paths)
    private lazy var usage = UsageStore(paths: paths)
    private lazy var toggles = CommandToggles(paths: paths)
    private lazy var hotKeys = CommandHotKeys(
        paths: paths,
        onLauncher: { [weak self] in self?.palette.toggle() },
        onCommand: { [weak self] id in
            // A command turned off in Settings → Commands ignores its hotkey too, as in Tauri.
            guard let self, self.toggles.isEnabled(id) else { return }
            self.palette.runCommand(id: id)
        }
    )

    var previousApplication: NSRunningApplication? { palette.previousApplication }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyPreferencesImport.runIfNeeded(paths: paths)
        Appearance.applyStoredTheme()
        NSApp.mainMenu = MainMenu.make(target: self)
        palette.onOpenSettings = { [weak self] in self?.openSettings(nil) }
        palette.onWillShow = { [weak self] in self?.applications.reload() }
        applications.onConfigure = { [weak self] name in
            ShortcutsSettingsPane.request(query: name)
            self?.openSettings(paneID: ShortcutsSettingsPane.id)
        }
        palette.model.onNotify = { [weak self] message in self?.showHUD(message) }

        let features = FeatureRegistry.make(context: self)
        let commands = PrismCommandsProvider(openSettings: { [weak self] in self?.openSettings(paneID: nil) },
                                             refreshApplications: { [weak self] in self?.applications.reload() })
        palette.model.install([applications, commands, WebProvider()] + features.flatMap(\.providers) + [WebFallbackProvider()])
        installFavorites()
        installBackupHooks()
        let model = palette.model
        // Updates sit at the top of General, as in the Tauri app, rather than in their own pane.
        let featurePanes = features.flatMap(\.settingsPanes)
        let updates = featurePanes.first { $0.id == UpdatesFeature.settingsPaneID }
        settings.install([
            GeneralSettingsPane.make(updates: updates?.content),
            LauncherSettingsPane.make(hotKeys: hotKeys),
            ShortcutsSettingsPane.make(hotKeys: hotKeys, aliases: aliases, toggles: toggles) { await model.allSearchableItems() },
        ] + featurePanes.filter { $0.id != UpdatesFeature.settingsPaneID })
        applications.reload()

        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--render-snapshots"), arguments.indices.contains(index + 1) {
            Task {
                await SnapshotRenderer.render(to: URL(filePath: arguments[index + 1]), palette: palette, settings: settings)
                NSApp.terminate(nil)
            }
            return
        }

        features.forEach { $0.start() }
        hotKeys.start()
        installStatusItem()
        if arguments.contains("--show-settings") { openSettings(nil) }
        if arguments.contains("--show-palette") { palette.show() }
    }

    /// Library owns favorites; the palette applies them to every provider's rows. Clipboard saves snippets
    /// through Library too, without the modules importing each other.
    private func installFavorites() {
        ClipboardFeature.onSaveAsSnippet = { LibraryFeature.createSnippet(text: $0) }
        palette.model.favoriteOrder = { LibraryFavorites.shared?.order(of: $0) }
        palette.model.favoriteAction = { LibraryFavorites.shared?.toggleAction(for: $0) }
        let usage = usage
        palette.model.usageBoost = { usage.boost(for: $0) }
        palette.model.onUse = { usage.record($0) }
        NotificationCenter.default.addObserver(forName: LibraryFavorites.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.palette.model.refresh() }
        }
    }

    /// Backup restore and Raycast import write other modules' files, then ask them to reload.
    private func installBackupHooks() {
        let model = palette.model
        let aliases = aliases
        let toggles = toggles
        model.aliases = { aliases.searchAliases }
        model.isDisabled = { !toggles.isEnabled($0) }
        NotificationCenter.default.addObserver(forName: CommandToggles.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.palette.model.refresh() }
        }
        BackupFeature.commandTitles = {
            Dictionary(await model.allSearchableItems().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        let hotKeys = hotKeys
        // Alias, hotkey and on/off controls inside feature panes (Window Management, Clipboard) edit the shell's stores.
        PrismCommandSettings.access = PrismCommandAccess(
            alias: { aliases.aliases[$0] ?? "" },
            setAlias: { aliases.setAlias($0, for: $1) },
            aliasesLocked: { aliases.isUnreadable },
            shortcut: { hotKeys.shortcut(for: $0) },
            setShortcut: { hotKeys.setShortcut($1, for: $0) },
            shortcutProblem: { hotKeys.failures.contains($0) ? String(localized: "Used by macOS or another app", bundle: .module) : nil },
            isEnabled: { toggles.isEnabled($0) },
            setEnabled: { toggles.setEnabled($1, for: $0) }
        )
        BackupFeature.shortcutAccess = BackupShortcutAccess(
            read: { (hotKeys.launcher.accelerator, hotKeys.commands) },
            setLauncher: { shortcut in
                hotKeys.setLauncher(shortcut)
                if hotKeys.launcherError != nil { throw BackupShortcutAccess.RegistrationError() }
            },
            setCommand: { id, shortcut in
                hotKeys.setShortcut(shortcut, for: id)
                if hotKeys.failures.contains(id) { throw BackupShortcutAccess.RegistrationError() }
            }
        )
        NotificationCenter.default.addObserver(forName: BackupFeature.dataDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            let changes = Set((note.userInfo?[BackupFeature.changesKey] as? [String]) ?? [])
            MainActor.assumeIsolated {
                if changes.contains(BackupDataChange.library.rawValue) { LibraryFeature.reload() }
                if changes.contains(BackupDataChange.appearance.rawValue) { Appearance.applyStoredTheme() }
                if changes.contains(BackupDataChange.aliases.rawValue) { self?.aliases.reload() }
                self?.palette.model.refresh()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        palette.show()
        return false
    }

    @objc func togglePalette(_ sender: Any?) { palette.toggle() }

    /// Runs the updates module's command row, which reports the result in a HUD.
    @objc func checkForUpdates(_ sender: Any?) { palette.runCommand(id: "prism:check-for-updates") }

    @objc func openSettings(_ sender: Any?) {
        openSettings(paneID: nil)
    }

    // MARK: PrismContext

    var isPaletteVisible: Bool { palette.panel.isVisible }
    var paletteFrame: NSRect? { palette.panel.isVisible ? palette.panel.frame : nil }
    func showPalette() { palette.show() }
    func hidePalette() { palette.hide() }
    func showPalette(screen: PaletteScreen) { palette.show(screen: screen) }
    func popScreen() { palette.model.popScreen() }
    func suspendPalette() { palette.panel.orderOut(nil) }
    func resumePalette() {
        NSApp.activate()
        palette.panel.makeKeyAndOrderFront(nil)
    }

    func reloadResults(providerID: String) {
        guard palette.panel.isVisible else { return }
        palette.model.reload(providerID: providerID)
    }

    func openSettings(paneID: String?) {
        palette.hide()
        settings.show(paneID: paneID)
    }

    func showHUD(_ message: String) { hud.show(message) }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Prism")
        let menu = NSMenu()
        menu.delegate = self
        let open = menu.addItem(withTitle: String(localized: "Open Prism", bundle: .module), action: #selector(togglePalette(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: String(localized: "Settings…", bundle: .module), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(withTitle: String(localized: "Check for Updates…", bundle: .module), action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Prism", bundle: .module), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Shows the current launcher shortcut, or why it could not be registered.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let open = menu.items.first else { return }
        open.title = String(localized: "Open Prism", bundle: .module) + "  " + hotKeys.launcher.displayName
        open.toolTip = hotKeys.launcherError
    }
}
