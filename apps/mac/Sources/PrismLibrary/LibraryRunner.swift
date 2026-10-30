import AppKit
import PrismKit

/// Runs library entries: opens links and paths, copies and pastes text. Dynamic entries are expanded first,
/// and the run screen shows the exact value before it runs.
@MainActor
final class LibraryRunner {
    enum Action: String {
        case open, copy, paste

        var title: String {
            switch self {
            case .open: L10n.tr("Open")
            case .copy: L10n.tr("Copy")
            case .paste: L10n.tr("Paste")
            }
        }
    }

    private weak var context: (any PrismContext)?
    private let model: LibraryModel
    /// The general pasteboard in the app; tests use a private one so they never touch the user's clipboard.
    var pasteboard = NSPasteboard.general

    init(context: any PrismContext, model: LibraryModel) {
        self.context = context
        self.model = model
    }

    /// The text or URL an action will use, with placeholders resolved now.
    func prepare(_ entry: LibraryEntry, query: String?) throws -> String {
        try LibraryValidation.validate(entry)
        var clipboard = ""
        if entry.kind == .snippet && entry.value.contains("{clipboard}") {
            guard let text = pasteboard.string(forType: .string) else { throw LibraryError.clipboardEmpty }
            guard text.utf8.count <= LibraryLimits.maxEntryBytes else { throw LibraryError.clipboardTooLong }
            clipboard = text
        }
        let now = LibraryTemplate.localDateTime()
        return try LibraryTemplate.expand(entry, query: query, date: now.date, time: now.time, clipboard: clipboard)
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Runs `value`, which `prepare` produced from `prepared`, after checking the entry was not edited meanwhile.
    func run(_ prepared: LibraryEntry, value: String, action: Action) async -> Result<PaletteActionOutcome, Error> {
        guard let current = model.entry(id: prepared.id) else { return .failure(LibraryError.entryDeleted) }
        guard current.kind == prepared.kind, current.value == prepared.value, current.title == prepared.title else {
            return .failure(LibraryError.entryChanged)
        }
        return await execute(current, value: value, action: action)
    }

    /// Runs a static entry directly.
    func run(_ entry: LibraryEntry, action: Action) async -> Result<PaletteActionOutcome, Error> {
        do {
            try LibraryValidation.validate(entry)
        } catch {
            return .failure(error)
        }
        return await execute(entry, value: entry.value, action: action)
    }

    private func execute(_ entry: LibraryEntry, value: String, action: Action) async -> Result<PaletteActionOutcome, Error> {
        switch (action, entry.kind) {
        case (.copy, _):
            copy(value)
            return .success(.notify(L10n.tr("Copied to Clipboard")))
        case (.paste, .snippet), (.paste, .note):
            context?.hidePalette()
            do {
                try await PasteService.paste(value, into: context?.previousApplication)
            } catch {
                context?.showHUD(L10n.tr("Copied. Allow Accessibility access to paste."))
            }
            return .success(.dismiss)
        case (.open, .link):
            do {
                let url = try LibraryValidation.validatedHTTPURL(value)
                NSWorkspace.shared.open(url)
                return .success(.dismiss)
            } catch {
                return .failure(error)
            }
        case (.open, .path):
            guard FileManager.default.fileExists(atPath: value) else { return .failure(LibraryError.pathMissing) }
            NSWorkspace.shared.open(URL(filePath: value))
            return .success(.dismiss)
        default:
            return .failure(LibraryError.unsupportedKind)
        }
    }
}
