import AppKit
import PrismKit
import SwiftUI

/// Everything the library feature shares between the palette, its screens and its windows.
@MainActor
final class LibraryServices {
    let model: LibraryModel
    let favorites: LibraryFavorites
    let runner: LibraryRunner
    private(set) weak var context: (any PrismContext)?
    /// Notes open inside the expanded palette, like the other library screens.
    private(set) lazy var notes = NotesPresenter(services: self)
    private(set) lazy var editor = EntryEditorController(model: model)

    init(context: any PrismContext, model: LibraryModel) {
        self.context = context
        self.model = model
        favorites = LibraryFavorites(model: model)
        runner = LibraryRunner(context: context, model: model)
    }

    // MARK: Screens

    func libraryScreen(tab: LibraryScreenModel.Tab) -> PaletteScreen {
        let screenModel = LibraryScreenModel(services: self, tab: tab)
        return PaletteScreen(id: "library", title: L10n.tr("Library"), expanded: true) {
            LibraryScreenView(model: screenModel)
        }
    }

    func runScreen(_ entry: LibraryEntry, action: LibraryRunner.Action) -> PaletteScreen {
        let runModel = LibraryRunModel(entry: entry, action: action, services: self)
        runModel.onFinished = { [weak self] in self?.context?.popScreen() }
        return PaletteScreen(id: "library-run-\(entry.id)", title: entry.title, expanded: true) {
            LibraryRunView(model: runModel, onBack: nil)
        }
    }

    func deleteScreen(_ entry: LibraryEntry) -> PaletteScreen {
        PaletteScreen(id: "library-delete-\(entry.id)", title: entry.title) { [weak self] in
            DeleteConfirmationView(entry: entry, onCancel: nil) {
                await self?.delete(entry, returnToRoot: true)
            }
        }
    }

    // MARK: Actions

    /// Row actions for one entry. The first runs on Return.
    func actions(for entry: LibraryEntry) -> [PaletteAction] {
        var actions: [PaletteAction] = []
        switch entry.kind {
        case .link, .path:
            actions.append(runAction(entry, .open, id: "library-open", symbol: entry.kind == .link ? "safari" : "arrow.up.forward.app"))
            actions.append(PaletteAction(id: "library-copy", title: entry.kind == .link ? L10n.tr("Copy Address") : L10n.tr("Copy Path"),
                                         systemImage: "doc.on.doc", shortcut: KeyboardShortcut("c", modifiers: [.command, .shift])) { [runner] in
                runner.copy(entry.value)
                return .notify(L10n.tr("Copied to Clipboard"))
            })
            if entry.kind == .path {
                actions.append(PaletteAction(id: "library-reveal", title: L10n.tr("Show in Finder"), systemImage: "folder",
                                             shortcut: KeyboardShortcut("r", modifiers: [.command, .shift])) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: entry.value)])
                    return .dismiss
                })
            }
        case .snippet:
            actions.append(runAction(entry, .copy, id: "library-copy", symbol: "doc.on.doc"))
            actions.append(runAction(entry, .paste, id: "library-paste", symbol: "doc.on.clipboard",
                                     shortcut: KeyboardShortcut(.return, modifiers: .command)))
        case .note:
            actions.append(PaletteAction(id: "library-edit", title: L10n.tr("Open"), systemImage: "note.text") { [weak self] in
                guard let self else { return .keepOpen }
                return .push(notes.screen(noteID: entry.id))
            })
            actions.append(PaletteAction(id: "library-copy", title: L10n.tr("Copy"), systemImage: "doc.on.doc",
                                         shortcut: KeyboardShortcut("c", modifiers: [.command, .shift])) { [runner] in
                runner.copy(entry.value)
                return .notify(L10n.tr("Copied to Clipboard"))
            })
        }
        if entry.kind != .note {
            actions.append(PaletteAction(id: "library-edit", title: L10n.tr("Edit"), systemImage: "pencil",
                                         shortcut: KeyboardShortcut("e", modifiers: .command)) { [weak self] in
                self?.edit(entry)
                return .dismiss
            })
        }
        actions.append(favorites.toggleAction(id: entry.paletteID, title: entry.title))
        actions.append(PaletteAction(id: "library-delete", title: L10n.tr("Delete…"), systemImage: "trash",
                                     shortcut: KeyboardShortcut("x", modifiers: .control), isDestructive: true) { [weak self] in
            guard let self else { return .keepOpen }
            return .push(deleteScreen(entry))
        })
        return actions
    }

    private func runAction(_ entry: LibraryEntry, _ action: LibraryRunner.Action, id: String, symbol: String,
                           shortcut: KeyboardShortcut? = nil) -> PaletteAction {
        PaletteAction(id: id, title: action.title, systemImage: symbol, shortcut: shortcut) { [weak self] in
            guard let self else { return .keepOpen }
            return await perform(entry, action: action)
        }
    }

    /// Dynamic entries open the preview screen; others run at once. Failures show as a notification.
    func perform(_ entry: LibraryEntry, action: LibraryRunner.Action) async -> PaletteActionOutcome {
        if entry.isDynamic { return .push(runScreen(entry, action: action)) }
        switch await runner.run(entry, action: action) {
        case .success(let outcome): return outcome
        case .failure(let error): return .notify(error.localizedDescription)
        }
    }

    /// Applies an outcome from inside a feature screen, where the palette does not handle it.
    func apply(_ outcome: PaletteActionOutcome) {
        switch outcome {
        case .dismiss: context?.hidePalette()
        case .keepOpen, .refresh: break
        case .notify(let message): context?.showHUD(message)
        case .push(let screen): context?.showPalette(screen: screen)
        }
    }

    func edit(_ entry: LibraryEntry) {
        if entry.kind == .note {
            notes.show(noteID: entry.id)
        } else {
            context?.hidePalette()
            editor.edit(entry)
        }
    }

    func create(_ kind: LibraryEntry.Kind, value: String = "") {
        if kind == .note {
            notes.showNewNote()
            return
        }
        context?.hidePalette()
        switch kind {
        case .note: break
        case .snippet:
            let title = String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
            editor.create(LibraryEntry(kind: .snippet, title: title, value: value))
        case .link, .path: editor.create(LibraryEntry(kind: kind, title: "", value: value))
        }
    }

    func delete(_ entry: LibraryEntry, returnToRoot: Bool) async {
        do {
            try await model.delete(id: entry.id)
            context?.showHUD(L10n.tr("Deleted"))
            if returnToRoot { context?.popScreen() }
        } catch {
            context?.showHUD(error.localizedDescription)
        }
    }
}
