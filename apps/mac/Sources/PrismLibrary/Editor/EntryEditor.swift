import AppKit
import Observation
import PrismKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class EntryEditorModel {
    var draft: LibraryEntry
    private(set) var original: LibraryEntry
    private(set) var isNew: Bool
    private(set) var error: String?
    private(set) var isSaving = false
    @ObservationIgnored private let model: LibraryModel

    init(entry: LibraryEntry, isNew: Bool, model: LibraryModel) {
        draft = entry
        original = entry
        self.isNew = isNew
        self.model = model
    }

    var isDirty: Bool { draft != original }

    var keywordIsValid: Bool { draft.kind != .snippet || LibraryValidation.isValidOptionalKeyword(draft.keyword) }

    var canSave: Bool {
        !isSaving && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.value.isEmpty && keywordIsValid
    }

    var windowTitle: String {
        switch (draft.kind, isNew) {
        case (.snippet, true): L10n.tr("New Snippet")
        case (.snippet, false): L10n.tr("Edit Snippet")
        case (_, true): L10n.tr("New Quicklink")
        case (_, false): L10n.tr("Edit Quicklink")
        }
    }

    var keywordBinding: String {
        get { draft.keyword ?? "" }
        set { draft.keyword = newValue.isEmpty ? nil : newValue }
    }

    func setLinkKind(_ kind: LibraryEntry.Kind) {
        guard kind != draft.kind else { return }
        draft.kind = kind
        draft.value = ""
    }

    /// Saves and returns true. A failed save keeps the editor and the input.
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        var entry = draft
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await model.save(entry)
            original = draft
            isNew = false
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

/// The quicklink and snippet editor: a small window with the flat fields of the Tauri library editor. ⌘S saves, Escape or ⌘W closes and
/// asks to save, discard or keep editing when there are unsaved changes.
@MainActor
final class EntryEditorController: NSObject, NSWindowDelegate {
    private let model: LibraryModel
    private var window: NSWindow?
    private var editor: EntryEditorModel?
    var onSaved: ((LibraryEntry) -> Void)?

    init(model: LibraryModel) {
        self.model = model
    }

    func create(_ entry: LibraryEntry) { present(EntryEditorModel(entry: entry, isNew: true, model: model)) }

    func edit(_ entry: LibraryEntry) { present(EntryEditorModel(entry: entry, isNew: false, model: model)) }

    private func present(_ next: EntryEditorModel) {
        if let window, let editor, editor.isDirty, editor.draft.id != next.draft.id {
            // Keep unsaved work; the user decides there first.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        editor = next
        let window = window ?? makeWindow()
        window.title = next.windowTitle
        window.contentView = NSHostingView(rootView: EntryEditorView(model: next, onCancel: { [weak self] in self?.close() },
                                                                     onSave: { [weak self] in self?.save() }))
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 520, height: 420))
        if !window.isVisible { window.center() }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    func save() {
        guard let editor, !TextInputState.isComposing else { return }
        Task {
            if await editor.save() {
                onSaved?(editor.draft)
                window?.orderOut(nil)
                self.editor = nil
            }
        }
    }

    func close() { window?.performClose(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let editor, editor.isDirty else {
            self.editor = nil
            return true
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Save your changes?")
        alert.informativeText = L10n.tr("Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L10n.tr("Save"))
        alert.addButton(withTitle: L10n.tr("Discard Changes"))
        alert.addButton(withTitle: L10n.tr("Keep Editing"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: save()
            case .alertSecondButtonReturn:
                self.editor = nil
                sender.orderOut(nil)
            default: break
            }
        }
        return false
    }
}

private final class EditorWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        // Escape first ends IME composition in the field; only an idle Escape closes.
        guard !TextInputState.isComposing else { return }
        performClose(sender)
    }
}

struct EntryEditorView: View {
    @Bindable var model: EntryEditorModel
    var onCancel: () -> Void
    var onSave: () -> Void
    @FocusState private var nameFocused: Bool

    /// `.library-editor`: labeled fields stacked 18 points apart, then the hint and the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(Text("Name", bundle: .module)) {
                TextField(text: $model.draft.title, prompt: Text(namePrompt).foregroundStyle(PrismTheme.textMuted)) {
                    Text("Name", bundle: .module)
                }
                .textFieldStyle(PrismTextFieldStyle(height: 35))
                .focused($nameFocused)
            }
            if model.draft.kind == .snippet {
                snippetFields
            } else {
                linkFields
            }
            if let error = model.error {
                Text(verbatim: error)
                    .font(.prism(12))
                    .foregroundStyle(PrismTheme.danger)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: hint)
                    .font(.prism(11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(L10n.tr("Cancel"), action: onCancel)
                    .buttonStyle(.prism)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("Save"), action: onSave)
                    .buttonStyle(.prismPrimary)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 25)
        .frame(width: 520)
        .background(Color(nsColor: PrismTheme.shellTint(opacity: 1)))
        .onAppear { nameFocused = true }
    }

    private func field<Content: View>(_ label: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .font(.prism(12))
                .foregroundStyle(PrismTheme.textSecondary)
            content()
        }
    }

    private var namePrompt: String {
        model.draft.kind == .snippet ? L10n.tr("Email signature") : L10n.tr("Search Google")
    }

    private var hint: String {
        switch model.draft.kind {
        case .snippet: L10n.tr("Use {date}, {time}, and {clipboard} for the date, time, and clipboard.")
        case .link: L10n.tr("Use {query} in the URL query to ask for a search term.")
        case .path, .note: L10n.tr("Opens with the default app.")
        }
    }

    @ViewBuilder
    private var linkFields: some View {
        field(Text("Type", bundle: .module)) {
            PrismSegmented(selection: Binding(get: { model.draft.kind }, set: { model.setLinkKind($0) }), options: [
                (LibraryEntry.Kind.link, L10n.tr("Web Link"), "globe"),
                (LibraryEntry.Kind.path, L10n.tr("File or Folder"), "folder"),
            ])
            .fixedSize()
        }
        if model.draft.kind == .link {
            field(Text("Address", bundle: .module)) {
                TextField(text: $model.draft.value, prompt: Text(verbatim: "https://www.google.com/search?q={query}").foregroundStyle(PrismTheme.textMuted)) {
                    Text("Address", bundle: .module)
                }
                .textFieldStyle(PrismTextFieldStyle(height: 35))
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
            }
        } else {
            field(Text("Path", bundle: .module)) {
                HStack(spacing: 8) {
                    if model.draft.value.isEmpty {
                        Text("None", bundle: .module).foregroundStyle(PrismTheme.textMuted)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.draft.value)).resizable().frame(width: 16, height: 16)
                        Text(verbatim: (model.draft.value as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(PrismTheme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(L10n.tr("Choose…")) { choosePath() }
                        .buttonStyle(.prism)
                }
                .font(.prism(12))
                .padding(.leading, 10)
                .padding(.trailing, 3)
                .frame(height: 37)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            }
        }
    }

    @ViewBuilder
    private var snippetFields: some View {
        field(Text("Content", bundle: .module)) {
            PrismTextEditor(text: $model.draft.value, minHeight: 170)
                .frame(maxHeight: 220)
        }
        field(Text("Keyword", bundle: .module)) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(text: $model.keywordBinding, prompt: Text(verbatim: ";email").foregroundStyle(PrismTheme.textMuted)) {
                    Text("Keyword", bundle: .module)
                }
                .textFieldStyle(PrismTextFieldStyle(height: 35))
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .frame(maxWidth: 220)
                Text(model.keywordIsValid
                     ? L10n.tr("Optional. Type it followed by a space to expand the snippet anywhere. Starts with ; ! / or :.")
                     : L10n.tr("Use 2–48 characters, starting with ; ! / or : and containing letters, numbers, _ - ; ! / :."))
                    .font(.prism(11))
                    .foregroundStyle(model.keywordIsValid ? PrismTheme.textMuted : PrismTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L10n.tr("Choose")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.draft.value = url.path
            if model.draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                model.draft.title = FileManager.default.displayName(atPath: url.path)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}
