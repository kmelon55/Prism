import PrismKit

/// Keyboard remapping: tap-and-hold keys (Space types a space when tapped and is ⌘ while held, Caps Lock is Escape
/// and Hyper), shortcut remaps everywhere or per app, and apps where tap-and-hold keys are left alone.
///
/// Off by default. While off, or with no rules, no event tap is installed and nothing runs.
public enum KeyboardFeature {
    public static let settingsPaneID = "keyboard"
    /// The Permissions pane in PrismSystem.
    static let permissionsPaneID = "permissions"

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let model = KeyboardModel(configURL: context.paths.file(KeyboardConfig.fileName))
        return FeatureContribution(
            settingsPanes: [
                SettingsPane(id: settingsPaneID, title: String(localized: "Keyboard", bundle: .module.prismLocalized), systemImage: "keyboard.badge.ellipsis",
                             group: .tools, order: 15, keywords: KeyboardSettingsView.keywords) { [weak context] in
                    KeyboardSettingsView(model: model) { context?.openSettings(paneID: permissionsPaneID) }
                },
            ],
            start: { model.start() }
        )
    }
}
