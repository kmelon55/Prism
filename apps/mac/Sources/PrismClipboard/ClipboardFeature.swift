import PrismCore
import PrismKit
import SwiftUI

/// Clipboard history: capture, storage, search, preview and paste.
public enum ClipboardFeature {
    /// Command IDs shared with the Tauri app, so saved command hotkeys and aliases keep working.
    public static let openHistoryCommandID = "clipboard:open-history"
    public static let clearHistoryCommandID = "clipboard:clear-history"
    public static let settingsPaneID = "clipboard"

    @MainActor private static var shared: ClipboardHistory?

    /// Set by the shell to open the snippet editor with a text entry's full original text. The action is
    /// hidden until this is set, so this module never depends on the library.
    @MainActor public static var onSaveAsSnippet: ((String) -> Void)?

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let history = history(context: context)
        let settings = ClipboardSettingsModel(history: history)
        return FeatureContribution(
            providers: [ClipboardCommandsProvider(history: history)],
            settingsPanes: [
                SettingsPane(id: settingsPaneID, title: ClipboardText.localize("Clipboard"), systemImage: "clipboard", group: .privacy, order: 0,
                             keywords: ["Clipboard shortcut", "Return action", "Clipboard history", "Capture status", "Excluded applications",
                                        "Keep history for", "Clear stored history", "Private by design"].map(ClipboardText.localize)) {
                    ClipboardSettingsView(model: settings)
                },
            ],
            start: { history.start() }
        )
    }

    /// The Clipboard History screen, for the command row and for a shell hotkey via
    /// `context.showPalette(screen:)`. Each call starts a fresh search.
    @MainActor
    public static func historyScreen(context: any PrismContext) -> PaletteScreen {
        let model = ClipboardHistoryModel(history: history(context: context))
        // A fresh ID per presentation, so reopening from a hotkey never reuses the previous view's state.
        return PaletteScreen(id: "clipboard-history-\(UUID().uuidString)", title: ClipboardText.localize("Clipboard History")) {
            ClipboardHistoryView(model: model)
        }
    }

    @MainActor
    private static func history(context: any PrismContext) -> ClipboardHistory {
        if let shared {
            shared.context = context
            return shared
        }
        let store = ClipboardStore.open(url: context.paths.file(ClipboardStore.fileName))
        let history = ClipboardHistory(store: store, context: context)
        shared = history
        return history
    }

    static func clearedMessage(_ removed: Int) -> String {
        removed == 0
            ? ClipboardText.localize("Clipboard history cleared")
            : String(format: ClipboardText.localize("Clipboard history cleared · %lld entries"), Int64(removed))
    }
}

/// Root rows: open the history screen and clear history.
@MainActor
final class ClipboardCommandsProvider: PaletteProvider {
    let id = "clipboard"
    private let history: ClipboardHistory

    init(history: ClipboardHistory) {
        self.history = history
    }

    func results(for query: String) async -> [PaletteItem] {
        let command = ClipboardText.localize("Command")
        return [
            PaletteItem(
                candidate: SearchCandidate(
                    id: ClipboardFeature.openHistoryCommandID,
                    title: ClipboardText.localize("Clipboard History"),
                    subtitle: ClipboardText.localize("Browse and reuse text copied on this device"),
                    section: ClipboardText.localize("Productivity"),
                    keywords: ["clipboard", "history", "copy", "paste", "recent", "클립보드", "기록", "복사", "붙여넣기"],
                    // Both languages, so "clipboard history" also matches a Korean interface.
                    searchAliases: ["Clipboard History", "클립보드 기록"]
                ),
                icon: .symbol("doc.on.clipboard", tint: .purple),
                accessory: command,
                actions: [
                    PaletteAction(id: "open-clipboard-history", title: ClipboardText.localize("Open Clipboard History"), systemImage: "doc.on.clipboard") { [history] in
                        guard let context = history.context else { return .keepOpen }
                        return .push(ClipboardFeature.historyScreen(context: context))
                    },
                ]
            ),
            PaletteItem(
                candidate: SearchCandidate(
                    id: ClipboardFeature.clearHistoryCommandID,
                    title: ClipboardText.localize("Clear clipboard history"),
                    subtitle: ClipboardText.localize("Remove every locally stored clipboard entry"),
                    section: ClipboardText.localize("Clipboard History"),
                    keywords: ["clipboard", "privacy", "clear", "delete", "클립보드", "삭제"],
                    searchAliases: ["Clear Clipboard History", "클립보드 기록 지우기"]
                ),
                icon: .symbol("trash", tint: .pink),
                accessory: command,
                actions: [
                    PaletteAction(id: "clear-clipboard-history", title: ClipboardText.localize("Clear clipboard history"), systemImage: "trash", isDestructive: true) { [history] in
                        do {
                            let removed = try await history.perform { store throws(ClipboardError) in try store.clear() }
                            ThumbnailLoader.shared.removeAll()
                            return .notify(ClipboardFeature.clearedMessage(removed))
                        } catch {
                            return .notify(error.localizedDescription)
                        }
                    },
                ]
            ),
        ]
    }
}
