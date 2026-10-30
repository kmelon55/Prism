import AppKit
import Observation
import PrismCore
import PrismKit
import SwiftUI

/// The notes workspace: a searchable list and one borderless Markdown document that saves on every edit.
/// It opens inside the expanded palette, as in the Tauri app (`NotesWorkspace.tsx`).
@MainActor
@Observable
final class NotesModel {
    var query = ""
    private(set) var document: LibraryEntry?
    private(set) var status: NoteAutosave.Status = .idle
    private(set) var isBusy = false
    var isPreviewing = false
    var isConfirmingDelete = false
    private(set) var focusToken = 0
    @ObservationIgnored private var autosave: NoteAutosave?
    @ObservationIgnored let library: LibraryModel

    init(library: LibraryModel) {
        self.library = library
    }

    var notes: [LibraryEntry] {
        let notes = library.entries(of: [.note])
        let needle = TextMatching.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return notes }
        return notes.filter {
            TextMatching.normalize($0.title).contains(needle) || (library.noteSearchIndex[$0.id] ?? "").contains(needle)
        }
    }

    /// The open document has been stored at least once.
    var isPersisted: Bool { document.map { library.entry(id: $0.id) != nil } ?? false }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    var documentText: String {
        get { document?.value ?? "" }
        set {
            guard var document, document.value != newValue else { return }
            // The first line is the title, so the stored title is derived again on save.
            document.title = ""
            document.value = newValue
            self.document = document
            autosave?.update(document)
        }
    }

    /// Opens the first note when nothing is open.
    func openInitial(noteID: String?) async {
        await library.loadIfNeeded()
        if let noteID, let entry = library.entry(id: noteID) {
            await select(entry)
        } else if document == nil {
            if let first = library.entries(of: [.note]).first {
                await select(first)
            } else {
                start(nil)
            }
        }
    }

    /// Waits for the latest write before switching. A failed write keeps the current note open.
    func select(_ entry: LibraryEntry?) async {
        guard !isBusy, entry == nil || entry?.id != document?.id else { return }
        isBusy = true
        defer { isBusy = false }
        guard await settle() else { return }
        start(entry)
        if entry == nil { query = "" }
    }

    private func start(_ entry: LibraryEntry?) {
        let next = entry.map(NoteMarkdown.forEditing) ?? LibraryEntry(kind: .note, title: "", value: "")
        document = next
        status = .idle
        isPreviewing = false
        isConfirmingDelete = false
        let fallback = L10n.tr("New Note")
        autosave = NoteAutosave(initial: next, persist: { [library] note in
            try await library.save(NoteMarkdown.forStorage(note, fallbackTitle: fallback))
        }, onStatus: { [weak self] status in
            self?.status = status
        })
        focusToken += 1
    }

    func settle() async -> Bool {
        await autosave?.settle() ?? true
    }

    func retrySave() {
        autosave?.flush()
    }

    func delete() async {
        guard let document, isPersisted, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard await settle() else { return }
        do {
            try await library.delete(id: document.id)
            isConfirmingDelete = false
            autosave = nil
            self.document = nil
            if let next = library.entries(of: [.note]).first {
                start(next)
            } else {
                start(nil)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

/// Opens the notes workspace as an expanded palette screen. One model lives as long as the app, so a note
/// that is still saving keeps saving after the screen closes, and reopening shows any save error.
@MainActor
final class NotesPresenter {
    private weak var services: LibraryServices?
    private let library: LibraryModel
    private(set) lazy var model = NotesModel(library: library)
    /// Whether the workspace is the visible palette screen, so opening a note there does not stack another.
    fileprivate var isOnScreen = false

    init(services: LibraryServices) {
        self.services = services
        library = services.model
    }

    func show(noteID: String? = nil) {
        present { model in await model.openInitial(noteID: noteID) }
    }

    func showNewNote() {
        present { model in
            await model.library.loadIfNeeded()
            await model.select(nil)
        }
    }

    /// The workspace as a palette screen, for actions that return `.push`.
    func screen(noteID: String? = nil) -> PaletteScreen {
        let model = model
        Task { await model.openInitial(noteID: noteID) }
        return makeScreen()
    }

    private func present(_ open: @escaping @MainActor (NotesModel) async -> Void) {
        let model = model
        if !isOnScreen { services?.context?.showPalette(screen: makeScreen()) }
        Task { await open(model) }
    }

    private func makeScreen() -> PaletteScreen {
        PaletteScreen(id: "notes", title: L10n.tr("Notes"), expanded: true) { [weak self, model] in
            NotesView(model: model, onBack: { self?.services?.context?.popScreen() })
                .onAppear { self?.isOnScreen = true }
                .onDisappear { self?.isOnScreen = false }
        }
    }
}

/// The workspace: a 230-point sidebar with the note list beside the document (`notes.css`).
struct NotesView: View {
    @Bindable var model: NotesModel
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
                .background(PrismTheme.surface)
            PrismVerticalRule()
            document
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if let onBack {
                    PrismBackButton(help: Text("Back", bundle: .module), action: onBack)
                }
                Text("Notes", bundle: .module)
                    .font(.prism(13, weight: 600))
                    .foregroundStyle(PrismTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrismIconButton(systemImage: "square.and.pencil", help: Text("New Note", bundle: .module)) {
                    Task { await model.select(nil) }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
                TextField(text: $model.query, prompt: Text("Search", bundle: .module).foregroundStyle(PrismTheme.textMuted)) {
                    Text("Search notes", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.prism(12))
                .foregroundStyle(PrismTheme.text)
            }
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.surface))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            NotesSidebarList(model: model)
        }
    }

    // MARK: Document

    private var document: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(verbatim: saveState)
                    .font(.prism(11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrismIconButton(systemImage: model.isPreviewing ? "pencil" : "eye",
                                help: Text(verbatim: model.isPreviewing ? L10n.tr("Edit Markdown") : L10n.tr("Preview Markdown")),
                                isActive: model.isPreviewing) {
                    model.isPreviewing.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.document == nil || model.isBusy)
                PrismIconButton(systemImage: "trash", help: Text("Delete Note", bundle: .module)) {
                    model.isConfirmingDelete = true
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.isPersisted || model.isBusy || model.isConfirmingDelete)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            Group {
                if model.document != nil {
                    if model.isPreviewing {
                        MarkdownPreview(source: model.documentText)
                            .onTapGesture(count: 2) { model.isPreviewing = false }
                    } else {
                        NoteTextView(text: $model.documentText, documentID: model.document?.id ?? "",
                                     isEditable: !model.isBusy && !model.isConfirmingDelete, focusToken: model.focusToken)
                            .overlay(alignment: .topLeading) {
                                if model.documentText.isEmpty {
                                    Text("Start writing…", bundle: .module)
                                        .font(.prism(15))
                                        .foregroundStyle(PrismTheme.textMuted)
                                        .padding(.leading, NoteStyle.inset.width + 5)
                                        .padding(.top, NoteStyle.inset.height + 4)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isConfirmingDelete {
                feedback(message: L10n.tr("Delete this note?"), isError: false) {
                    Button(L10n.tr("Cancel")) { model.isConfirmingDelete = false }
                        .buttonStyle(.prism)
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.tr("Delete")) { Task { await model.delete() } }
                        .buttonStyle(.prismDestructive)
                        .keyboardShortcut(.defaultAction)
                }
            } else if let error = model.errorMessage {
                feedback(message: error, isError: true) {
                    Button(L10n.tr("Retry Save")) { model.retrySave() }
                        .buttonStyle(.prism)
                }
            }
        }
    }

    private var saveState: String {
        switch model.status {
        case .saving: L10n.tr("Saving…")
        case .saved: model.isPersisted ? L10n.tr("Saved") : ""
        case .idle, .failed: ""
        }
    }

    /// `.notes-feedback`: a line under the document with its buttons.
    private func feedback<Buttons: View>(message: String, isError: Bool, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: message)
                .font(.prism(12))
                .foregroundStyle(isError ? PrismTheme.danger : PrismTheme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            buttons()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { PrismRule() }
    }
}

/// The note list (`.notes-list`): title and first line, the open note filled.
struct NotesSidebarList: View {
    @Bindable var model: NotesModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                if let document = model.document, !model.isPersisted, model.query.isEmpty {
                    NoteListRow(title: NoteMarkdown.title(document.value).nonEmpty ?? L10n.tr("New Note"),
                                excerpt: NoteMarkdown.excerpt(document.value), isCurrent: true)
                }
                ForEach(model.notes) { note in
                    let isCurrent = note.id == model.document?.id
                    NoteListRow(title: isCurrent ? (NoteMarkdown.title(model.documentText).nonEmpty ?? note.title) : note.title,
                                excerpt: NoteMarkdown.excerpt(isCurrent ? model.documentText : note.value), isCurrent: isCurrent)
                        .onTapGesture {
                            guard !isCurrent, let entry = model.library.entry(id: note.id) else { return }
                            Task { await model.select(entry) }
                        }
                }
                if !model.query.isEmpty && model.notes.isEmpty {
                    Text("No results found.", bundle: .module)
                        .font(.prism(12))
                        .foregroundStyle(PrismTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }
}

private struct NoteListRow: View {
    let title: String
    let excerpt: String
    let isCurrent: Bool
    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.prism(13, weight: 550))
                .foregroundStyle(PrismTheme.text)
                .lineLimit(1)
            if !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.prism(11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isCurrent || hovering ? PrismTheme.surfaceSelected : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
