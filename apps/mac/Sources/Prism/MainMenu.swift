import AppKit

/// Accessory apps have no visible menu bar, but key equivalents such as ⌘, ⌘Q and the Edit
/// commands in text fields still route through the main menu while Prism is active.
enum MainMenu {
    @MainActor
    static func make(target: AppDelegate) -> NSMenu {
        let menu = NSMenu()

        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: String(localized: "Settings…", bundle: .module), action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(withTitle: String(localized: "Check for Updates…", bundle: .module), action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Prism", bundle: .module), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        // No ⌘Q: a stray ⌘Q while typing in the launcher must not quit it (Tauri had none either).
        // Quit stays available here, in the status menu and as the "Quit Prism" command.
        appMenu.addItem(withTitle: String(localized: "Quit Prism", bundle: .module), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Prism", action: nil, keyEquivalent: "").submenu = appMenu

        let editMenu = NSMenu(title: String(localized: "Edit", bundle: .module))
        editMenu.addItem(withTitle: String(localized: "Undo", bundle: .module), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo", bundle: .module), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut", bundle: .module), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy", bundle: .module), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste", bundle: .module), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All", bundle: .module), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: String(localized: "Edit", bundle: .module), action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: String(localized: "Window", bundle: .module))
        windowMenu.addItem(withTitle: String(localized: "Close", bundle: .module), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: String(localized: "Window", bundle: .module), action: nil, keyEquivalent: "").submenu = windowMenu
        return menu
    }
}
