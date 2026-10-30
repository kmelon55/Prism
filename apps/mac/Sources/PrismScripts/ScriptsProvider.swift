import AppKit
import PrismCore
import PrismKit
import SwiftUI
import UniformTypeIdentifiers

/// Root search rows for script commands. Row IDs match the Tauri app (`script:sc_…`), so saved hotkeys and
/// aliases keep pointing at the same command.
@MainActor
final class ScriptsProvider: PaletteProvider {
    static let providerID = "script-commands"

    let id = ScriptsProvider.providerID
    let model: ScriptsModel
    let actions: ScriptActions

    init(model: ScriptsModel, actions: ScriptActions) {
        self.model = model
        self.actions = actions
    }

    func results(for query: String) async -> [PaletteItem] {
        await model.bootstrap()
        return model.commands.map(item)
    }

    static func itemID(_ scriptID: String) -> String { "script:\(scriptID)" }

    func item(_ command: ScriptCommandSummary) -> PaletteItem {
        let session = model.session(command.id)
        var subtitle = command.description ?? command.packageName ?? ""
        if command.mode == .inline, let snapshot = session.snapshot, snapshot.state == .success, let line = ScriptOutput.firstLine(snapshot.stdout) {
            subtitle = ScriptOutput.truncated(line, to: 80)
        }
        let candidate = SearchCandidate(
            id: Self.itemID(command.id), title: command.title, subtitle: subtitle,
            section: ScriptStrings.localized("Script commands"),
            keywords: ["script", "local", ScriptStrings.localized("Script")] + command.keywords + [command.packageName].compactMap { $0 }
        )
        let accessory = session.isRunning ? ScriptStrings.localized("Running") : ScriptStrings.localized("Script")
        return PaletteItem(candidate: candidate, icon: actions.icon(for: command), accessory: accessory, actions: rowActions(command, session: session))
    }

    private func rowActions(_ command: ScriptCommandSummary, session: ScriptSession) -> [PaletteAction] {
        let id = command.id
        var list = [
            PaletteAction(
                id: "run-script-command", title: session.isRunning ? ScriptStrings.localized("Show Output") : ScriptStrings.localized("Run Script"),
                systemImage: session.isRunning ? "text.alignleft" : "play.fill"
            ) { [actions] in await actions.runPrimary(id) },
        ]
        if session.snapshot != nil && !session.isRunning {
            list.append(PaletteAction(id: "show-script-output", title: ScriptStrings.localized("Show Output"), systemImage: "text.alignleft",
                                      shortcut: KeyboardShortcut("o", modifiers: .command)) { [actions] in .push(actions.screen(id)) })
        }
        if session.snapshot?.state == .running {
            list.append(PaletteAction(id: "cancel-script-run", title: ScriptStrings.localized("Cancel Run"), systemImage: "stop.fill",
                                      shortcut: KeyboardShortcut(".", modifiers: .command), isDestructive: true) { [model] in
                await model.cancel(id)
                return .refresh
            })
        }
        if model.inlineRefreshIsActive(id) {
            list.append(PaletteAction(id: "stop-script-refresh", title: ScriptStrings.localized("Stop Refreshing"), systemImage: "arrow.clockwise.circle") { [model] in
                model.stopInlineRefresh(id)
                return .refresh
            })
        }
        list.append(PaletteAction(id: "reveal-script-command", title: ScriptStrings.localized("Show in Finder"), systemImage: "folder",
                                  shortcut: KeyboardShortcut("r", modifiers: [.command, .shift])) { [actions] in
            actions.reveal(id) ? .dismiss : .keepOpen
        })
        list.append(PaletteAction(id: "edit-script-command", title: ScriptStrings.localized("Edit Script"), systemImage: "pencil",
                                  shortcut: KeyboardShortcut("e", modifiers: .command)) { [actions] in
            actions.edit(id) ? .dismiss : .keepOpen
        })
        return list
    }
}

/// What running a command does, shared by root rows and the run screen.
@MainActor
final class ScriptActions {
    let model: ScriptsModel
    unowned let context: any PrismContext
    private let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    init(model: ScriptsModel, context: any PrismContext) {
        self.model = model
        self.context = context
    }

    func screen(_ scriptID: String) -> PaletteScreen {
        PaletteScreen(id: "scripts:run:\(scriptID)", title: model.command(scriptID)?.title ?? ScriptStrings.localized("Script command")) {
            ScriptRunView(model: self.model, actions: self, scriptID: scriptID)
        }
    }

    /// Return on a row. Arguments, confirmation, metadata errors and an interrupted previous run open the run
    /// screen first; otherwise the command runs in its Raycast output mode. A running command is shown, never
    /// started twice.
    func runPrimary(_ scriptID: String) async -> PaletteActionOutcome {
        guard let command = model.command(scriptID) else { return .notify(ScriptStrings.localize("The script command is not present in the current registry.")) }
        let session = model.session(scriptID)
        if session.isRunning || command.argumentError != nil || !command.arguments.isEmpty || command.needsConfirmation
            || session.snapshot?.state == .interrupted {
            return .push(screen(scriptID))
        }
        switch command.mode {
        case .fullOutput:
            Task { await model.start(scriptID, arguments: []) }
            return .push(screen(scriptID))
        case .compact, .inline:
            if command.mode == .inline { model.enableInlineRefresh(scriptID) }
            await model.start(scriptID, arguments: [])
            if let error = model.session(scriptID).error { return .notify(ScriptStrings.localize(error)) }
            let finished = await model.waitForCompletion(scriptID)
            return .notify(finished.map { message(for: $0, mode: command.mode) } ?? ScriptStrings.localized("Script succeeded"))
        case .silent:
            runSilently(scriptID, arguments: [])
            return .dismiss
        }
    }

    /// Runs a silent command after the palette hides and reports its last line in a HUD.
    func runSilently(_ scriptID: String, arguments: [String]) {
        Task {
            await model.start(scriptID, arguments: arguments)
            if let error = model.session(scriptID).error {
                context.showHUD(ScriptStrings.localize(error))
                return
            }
            if let finished = await model.waitForCompletion(scriptID) {
                context.showHUD(message(for: finished, mode: .silent))
            }
        }
    }

    func message(for snapshot: ScriptRunSnapshot, mode: ScriptOutputMode) -> String {
        switch snapshot.state {
        case .success:
            let line = mode == .inline ? ScriptOutput.firstLine(snapshot.stdout) : ScriptOutput.lastLine(snapshot.stdout)
            return ScriptOutput.truncated(line ?? ScriptStrings.localized("Script succeeded"))
        case .timedOut:
            return ScriptStrings.localized("Script timed out after \(Int(snapshot.timeoutSeconds)) seconds")
        case .cancelled:
            return ScriptStrings.localized("Script cancelled")
        case .interrupted:
            return ScriptStrings.localized("Script interrupted")
        case .failure, .running:
            let detail = ScriptOutput.lastLine(snapshot.stderr) ?? ScriptOutput.lastLine(snapshot.stdout) ?? snapshot.error.map(ScriptStrings.localize)
            let failed = ScriptStrings.localized("Script failed")
            return ScriptOutput.truncated(detail.map { "\(failed): \($0)" } ?? failed)
        }
    }

    func reveal(_ scriptID: String) -> Bool {
        guard let url = model.registry.scriptURL(for: scriptID) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    /// Opens the script in the default text editor. Opening it with its default app would run it in Terminal.
    func edit(_ scriptID: String) -> Bool {
        guard let url = model.registry.scriptURL(for: scriptID) else { return false }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        guard let editor else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    func icon(for command: ScriptCommandSummary) -> PaletteIcon {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch (dark ? command.iconDark ?? command.icon : command.icon) {
        case .emoji(let emoji): return .text(emoji)
        case .image(let path):
            if let cached = icons.object(forKey: path as NSString) { return .image(cached) }
            if let image = NSImage(contentsOfFile: path) {
                image.size = NSSize(width: 28, height: 28)
                icons.setObject(image, forKey: path as NSString)
                return .image(image)
            }
            return .symbol("terminal")
        case nil: return .symbol("terminal")
        }
    }
}
