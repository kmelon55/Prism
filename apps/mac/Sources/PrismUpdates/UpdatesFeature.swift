import PrismKit

/// Checking for, downloading, verifying and installing app updates from the Tauri updater feed.
///
/// Settings get their own "Updates" pane (order 850). The palette shows "Check for updates" when searched, and an
/// update row while an update is available, installing, installed or failed. Network requests happen only in
/// the scheduled checks (20 seconds after launch, then every six hours) and when the user asks.
public enum UpdatesFeature {
    public static let settingsPaneID = "updates"

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let controller = UpdateController(
            environment: .live(),
            preferencesURL: context.paths.file(UpdatePreferences.fileName)
        )
        let provider = UpdatesProvider(controller: controller)
        var reloadScheduled = false
        controller.onChange = { [weak context] in
            // Several status changes in one turn (for example checking → available → installing) reload once.
            guard !reloadScheduled else { return }
            reloadScheduled = true
            Task { @MainActor in
                reloadScheduled = false
                context?.reloadResults(providerID: UpdatesProvider.providerID)
            }
        }
        return FeatureContribution(
            providers: [provider],
            settingsPanes: [
                SettingsPane(id: settingsPaneID, title: String(localized: "Updates", bundle: .module),
                             systemImage: "arrow.triangle.2.circlepath", order: 850) {
                    UpdatesSettingsView(controller: controller)
                },
            ],
            start: { controller.startSchedule() }
        )
    }
}
