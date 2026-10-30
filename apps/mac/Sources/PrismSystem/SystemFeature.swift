import PrismKit

/// System commands, power, window management, permissions and launch at login.
///
/// The shell places `LaunchAtLoginToggle()` in its General pane; command hotkeys run rows by their IDs
/// (`window:left-half`, `system:sleep`, …), so this feature registers no hotkeys itself.
public enum SystemFeature {
    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let store = WindowOptionsStore(url: context.paths.file(WindowOptionsStore.fileName))
        let windows = WindowCommandController(context: context, manager: WindowManager(options: store.loadOrDefault))
        let runner = SystemActionRunner(context: context)
        return FeatureContribution(
            providers: [
                SystemCommandsProvider(runner: runner),
                WindowCommandsProvider(controller: windows),
            ],
            settingsPanes: [
                WindowManagementPane.make(store: store, context: context),
                PermissionsPane.make(),
            ]
        )
    }
}
