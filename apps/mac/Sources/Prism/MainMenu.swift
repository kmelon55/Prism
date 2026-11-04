import PrismKit
import AppKit

/// Accessory apps have no visible menu bar, but key equivalents such as ⌘, ⌘Q and the Edit
/// commands in text fields still route through the main menu while Prism is active.
enum MainMenu {
    @MainActor
    static func make(target: AppDelegate) -> NSMenu {
        let menu = NSMenu()

        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: String(localized: "Settings…", bundle: .module.prismLocalized), action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(withTitle: String(localized: "Check for Updates…", bundle: .module.prismLocalized), action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Prism", bundle: .module.prismLocalized), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        // No ⌘Q: a stray ⌘Q while typing in the launcher must not quit it (Tauri had none either).
        // Quit stays available here, in the status menu and as the "Quit Prism" command.
        appMenu.addItem(withTitle: String(localized: "Quit Prism", bundle: .module.prismLocalized), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Prism", action: nil, keyEquivalent: "").submenu = appMenu

        let editMenu = NSMenu(title: String(localized: "Edit", bundle: .module.prismLocalized))
        editMenu.addItem(withTitle: String(localized: "Undo", bundle: .module.prismLocalized), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo", bundle: .module.prismLocalized), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut", bundle: .module.prismLocalized), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy", bundle: .module.prismLocalized), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste", bundle: .module.prismLocalized), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All", bundle: .module.prismLocalized), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: String(localized: "Edit", bundle: .module.prismLocalized), action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: String(localized: "Window", bundle: .module.prismLocalized))
        windowMenu.addItem(withTitle: String(localized: "Close", bundle: .module.prismLocalized), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: String(localized: "Window", bundle: .module.prismLocalized), action: nil, keyEquivalent: "").submenu = windowMenu
        let keys = [
            ["Settings…", "Check for Updates…", "Hide Prism", "Quit Prism"],
            ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"],
            ["Close"],
        ]
        for (submenu, titles) in zip([appMenu, editMenu, windowMenu], keys) {
            for (item, key) in zip(submenu.items.filter { !$0.isSeparatorItem }, titles) {
                item.identifier = NSUserInterfaceItemIdentifier("prism.localized." + key)
            }
        }
        menu.items[1].identifier = NSUserInterfaceItemIdentifier("prism.localized.Edit")
        menu.items[2].identifier = NSUserInterfaceItemIdentifier("prism.localized.Window")
        return menu
    }

    /// Update our items in place; rebuilding the menu makes AppKit insert its system items again.
    @MainActor
    static func refreshLanguage(_ menu: NSMenu) {
        for item in menu.items {
            if let id = item.identifier?.rawValue, id.hasPrefix("prism.localized.") {
                let key = String(id.dropFirst("prism.localized.".count))
                item.title = String(localized: String.LocalizationValue(key), bundle: .module.prismLocalized)
                item.submenu?.title = item.title
            }
            if let submenu = item.submenu { refreshLanguage(submenu) }
        }
    }
}
