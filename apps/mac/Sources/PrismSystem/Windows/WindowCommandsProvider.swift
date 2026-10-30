import AppKit
import PrismCore
import PrismKit

/// Window layout commands. Like the Tauri catalog they stay out of the empty root list; hotkeys run them
/// through their `window:` command IDs.
@MainActor
final class WindowCommandsProvider: PaletteProvider {
    let id = "window-management"
    private let controller: WindowCommandController

    init(controller: WindowCommandController) {
        self.controller = controller
    }

    func results(for query: String) async -> [PaletteItem] {
        // Returned for the empty query too: the shell resolves hotkeys and the Shortcuts pane through it.
        WindowLayout.allCases.map(item)
    }

    private func item(_ layout: WindowLayout) -> PaletteItem {
        let subtitle = layout == .restorePreviousLayout
            ? String(localized: "Restore the frontmost window to its previous Prism layout", bundle: .module)
            : String(localized: "Move the frontmost window to \(layout.title.lowercased())", bundle: .module)
        return PaletteItem(
            candidate: SearchCandidate(
                id: layout.commandID, title: layout.title, subtitle: subtitle,
                section: String(localized: "Window Management", bundle: .module),
                keywords: layout.keywords, searchAliases: SystemStrings.bilingual(layout.englishTitle)
            ),
            icon: .image(WindowLayoutIcon.image(for: layout)),
            accessory: String(localized: "Window", bundle: .module),
            actions: [
                PaletteAction(id: "manage-window-\(layout.rawValue)", title: String(localized: "Apply \(layout.title)", bundle: .module),
                              systemImage: "macwindow") { [controller] in
                    controller.run(layout)
                },
            ],
            hiddenWhenQueryIsEmpty: true
        )
    }
}

/// Resolves the target window, applies a layout and turns failures into a visible message.
@MainActor
final class WindowCommandController {
    private unowned let context: any PrismContext
    let manager: WindowManager

    init(context: any PrismContext, manager: WindowManager) {
        self.context = context
        self.manager = manager
    }

    /// The app to arrange. The palette is a non-activating panel, so the frontmost app is still the one the user
    /// was working in; when Prism itself is frontmost (its Settings window), fall back to the app before the palette.
    var targetApplication: NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            return frontmost
        }
        return context.previousApplication.flatMap { $0.isTerminated ? nil : $0 }
    }

    func run(_ layout: WindowLayout) -> PaletteActionOutcome {
        do throws(WindowActionError) {
            guard let application = targetApplication else { throw .make(.noTarget) }
            let window = try AccessibilityWindow(application: application)
            try manager.apply(layout, to: window)
            if !application.isActive { application.activate() }
            return .dismiss
        } catch {
            if error.code == .accessibilityRequired {
                context.openSettings(paneID: PermissionsPane.id)
                context.showHUD(String(localized: "Accessibility access required", bundle: .module))
                return .dismiss
            }
            return .notify(error.message)
        }
    }
}
