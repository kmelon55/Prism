import Observation
import PrismKit
import SwiftUI

/// Script commands compatible with the Raycast script command format.
public enum ScriptsFeature {
    public static let settingsPaneID = "scripts"

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let model = ScriptsModel(paths: context.paths)
        let actions = ScriptActions(model: model, context: context)
        let pane = SettingsPane(id: settingsPaneID, title: String(localized: "Scripts", bundle: .module), systemImage: "terminal", group: .tools, order: 40,
                                keywords: ScriptsSettingsView.keywords) {
            ScriptsSettingsView(model: model, actions: actions)
        }
        return FeatureContribution(
            providers: [ScriptsProvider(model: model, actions: actions)],
            settingsPanes: [pane],
            start: {
                // Startup refresh, then FSEvents keep the registry current. Discovery never runs a script.
                model.startWatching()
                observeRows(model, context: context)
            }
        )
    }

    /// Reloads the script rows when commands or run state change on their own (a run finishing, an inline
    /// refresh, a folder change), coalesced so streaming output does not re-rank the palette constantly.
    @MainActor
    static func observeRows(_ model: ScriptsModel, context: any PrismContext) {
        withObservationTracking {
            _ = model.commands
            _ = model.sessions
        } onChange: { [weak model, weak context] in
            Task { @MainActor in
                guard let model, let context else { return }
                // Tracking fires once; changes during the wait are covered by the reload that follows it.
                try? await Task.sleep(for: .milliseconds(400))
                context.reloadResults(providerID: ScriptsProvider.providerID)
                observeRows(model, context: context)
            }
        }
    }
}
