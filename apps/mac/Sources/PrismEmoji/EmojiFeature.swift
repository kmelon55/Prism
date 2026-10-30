import AppKit
import PrismCore
import PrismKit

/// Emoji picker: a `prism:emoji` command that opens a searchable emoji grid. Return pastes into the app that
/// was frontmost before the palette opened; ⌘Return copies.
public enum EmojiFeature {
    public static let commandID = "prism:emoji"

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        FeatureContribution(providers: [EmojiCommandProvider(context: context)])
    }

    @MainActor
    static func screen(context: any PrismContext) -> PaletteScreen {
        let recents = EmojiRecents(url: context.paths.file("emoji-recent-v1.json"))
        let actions = EmojiActions(
            copy: { PasteService.copy($0) },
            paste: { [weak context] emoji in
                let target = context?.previousApplication
                context?.hidePalette()
                try await PasteService.paste(emoji, into: target)
            },
            canPaste: { Permissions.isAccessibilityTrusted }
        )
        // Built once per opening: the palette may evaluate the screen's content many times.
        let close: () -> Void = { [weak context] in context?.popScreen() }
        let openAccessibilitySettings = { [weak context] in
            context?.hidePalette()
            Permissions.openAccessibilitySettings()
        }
        let model = EmojiPickerModel(actions: actions, recents: recents) { await EmojiCatalogLoader.shared.load() }
        return PaletteScreen(id: "emoji", title: String(localized: "Emoji", bundle: .module), expanded: true) {
            EmojiPickerView(
                model: model,
                onClose: close,
                onOpenAccessibilitySettings: openAccessibilitySettings
            )
        }
    }
}

@MainActor
final class EmojiCommandProvider: PaletteProvider {
    let id = "emoji"
    private weak var context: (any PrismContext)?

    init(context: any PrismContext) {
        self.context = context
    }

    func results(for query: String) async -> [PaletteItem] {
        guard let context else { return [] }
        let candidate = SearchCandidate(
            id: EmojiFeature.commandID,
            title: String(localized: "Emoji", bundle: .module),
            subtitle: String(localized: "Find emoji to copy or paste", bundle: .module),
            section: String(localized: "Productivity", bundle: .module),
            keywords: ["emoji", "emojis", "이모지", "이모티콘", "표정", "symbols", "emoticon"],
            searchAliases: ["Emoji", "이모지"]
        )
        return [PaletteItem(
            candidate: candidate,
            icon: .symbol("face.smiling", tint: .orange),
            accessory: String(localized: "Command", bundle: .module),
            actions: [
                PaletteAction(id: "open-emoji", title: String(localized: "Open", bundle: .module), systemImage: "face.smiling") { [weak context] in
                    guard let context else { return .keepOpen }
                    return .push(EmojiFeature.screen(context: context))
                },
            ]
        )]
    }
}
