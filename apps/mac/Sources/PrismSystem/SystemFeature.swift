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
        let awake = KeepAwakeModel()
        let audio = AudioOutputModel()
        let mixer = AudioMixerModel(url: context.paths.file("app-audio-v1.json"))
        return FeatureContribution(
            providers: [
                SystemCommandsProvider(runner: runner),
                WindowCommandsProvider(controller: windows),
                UtilitiesProvider(awake: awake, audio: audio, mixer: mixer),
            ],
            settingsPanes: [
                WindowManagementPane.make(store: store, context: context),
                PermissionsPane.make(),
            ],
            notchWidgets: utilityWidgets(awake: awake, audio: audio, mixer: mixer),
            start: { awake.observeLifecycle(); mixer.observeLifecycle() }
        )
    }
}
