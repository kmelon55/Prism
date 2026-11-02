import PrismKit
import PrismCalculator
import PrismClipboard
import PrismLibrary
import PrismFiles
import PrismEmoji
import PrismSystem
import PrismUpdates
import PrismScripts
import PrismAI
import PrismDictation
import PrismBackup
import PrismNotch
import PrismKeyboard

/// Every feature module, in the order their providers are asked for results.
@MainActor
enum FeatureRegistry {
    static func make(context: any PrismContext) -> [FeatureContribution] {
        let features = [
            CalculatorFeature.make(context: context),
            ClipboardFeature.make(context: context),
            LibraryFeature.make(context: context),
            FileSearchFeature.make(context: context),
            EmojiFeature.make(context: context),
            SystemFeature.make(context: context),
            ScriptsFeature.make(context: context),
            AIFeature.make(context: context),
            DictationFeature.make(context: context),
            BackupFeature.make(context: context),
            UpdatesFeature.make(context: context),
            KeyboardFeature.make(context: context),
        ]
        return features + [NotchFeature.make(context: context, widgets: features.flatMap(\.notchWidgets))]
    }
}
