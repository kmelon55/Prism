import PrismCore
import PrismKit
import SwiftUI

/// Dictation: recording, transcription, overlay and text insertion.
public enum DictationFeature {
    public static let settingsPaneID = "dictation"

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let service = DictationService(paths: context.paths, context: context)
        return FeatureContribution(
            providers: [DictationCommandsProvider(service: service, context: context)],
            settingsPanes: [
                SettingsPane(id: settingsPaneID, title: String(localized: "Dictation", bundle: .module), systemImage: "mic", order: 30,
                             keywords: ["Current model", "Dictation enhancement", "Refine speech", "Structure prompt", "Default action",
                                        "Waveform overlay", "Spoken language", "Recognition hints and vocabulary", "Permissions", "Dictation Recovery"]
                                 .map { String(localized: String.LocalizationValue($0), bundle: .module) } + ["Whisper", "whisper.cpp", "STT"]) {
                    DictationSettingsView(service: service)
                },
            ],
            start: { service.start() }
        )
    }
}

/// The two launcher commands. Their IDs match the Tauri app, so saved command shortcuts keep working.
@MainActor
final class DictationCommandsProvider: PaletteProvider {
    let id = "dictation"
    private let service: DictationService
    private weak var context: (any PrismContext)?

    init(service: DictationService, context: any PrismContext) {
        self.service = service
        self.context = context
    }

    func results(for query: String) async -> [PaletteItem] {
        let recording = service.controller.phase == .recording
        let section = String(localized: "Productivity", bundle: .module)
        return [
            PaletteItem(
                candidate: SearchCandidate(
                    id: CommandShortcutsFile.dictationCommand,
                    title: String(localized: "Dictation", bundle: .module),
                    subtitle: String(localized: "Start recording · Run again to transcribe and insert", bundle: .module),
                    section: section,
                    keywords: ["dictation", "whisp", "voice", "speech", "transcribe", "음성", "받아쓰기", "녹음", "전사"]),
                icon: .symbol("mic.fill", tint: .red),
                accessory: String(localized: "Command", bundle: .module),
                actions: [
                    PaletteAction(id: "toggle-dictation",
                                  title: recording ? String(localized: "Finish Dictation", bundle: .module) : String(localized: "Start Dictation", bundle: .module),
                                  systemImage: recording ? "stop.circle" : "mic") { [service] in
                        service.toggle(promptMode: false)
                        return .dismiss
                    },
                    settingsAction,
                ]),
            PaletteItem(
                candidate: SearchCandidate(
                    id: CommandShortcutsFile.promptCommand,
                    title: String(localized: "Structure prompt", bundle: .module),
                    subtitle: String(localized: "Speak to create a clear prompt · Run again to insert", bundle: .module),
                    section: section,
                    keywords: ["dictation", "prompt", "프롬프트", "정리", "음성"]),
                icon: .symbol("wand.and.stars", tint: .purple),
                accessory: String(localized: "Command", bundle: .module),
                actions: [
                    PaletteAction(id: "toggle-dictation-prompt", title: String(localized: "Structure prompt", bundle: .module),
                                  systemImage: "wand.and.stars") { [service] in
                        service.toggle(promptMode: true)
                        return .dismiss
                    },
                    settingsAction,
                ]),
        ]
    }

    private var settingsAction: PaletteAction {
        PaletteAction(id: "dictation-settings", title: String(localized: "Dictation Settings", bundle: .module), systemImage: "gearshape") { [weak context] in
            context?.openSettings(paneID: DictationFeature.settingsPaneID)
            return .dismiss
        }
    }
}
