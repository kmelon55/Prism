import PrismCore
import PrismKit
import SwiftUI

@MainActor
final class UtilitiesProvider: PaletteProvider {
    let id = "utilities"
    private let awake: KeepAwakeModel
    private let audio: AudioOutputModel
    private let mixer: AudioMixerModel?

    init(awake: KeepAwakeModel, audio: AudioOutputModel, mixer: AudioMixerModel? = nil) {
        self.awake = awake; self.audio = audio; self.mixer = mixer
    }

    func results(for query: String) async -> [PaletteItem] {
        let awake = awake, audio = audio
        var items = [
            item("keep-awake", title: "Keep Awake", symbol: "cup.and.saucer",
                 keywords: ["caffeine", "sleep", "잠자기", "절전", "방지"]) {
                .push(PaletteScreen(id: "keep-awake", title: SystemStrings.localized("Keep Awake")) {
                    KeepAwakeView(model: awake).padding(24)
                })
            },
            item("audio-output", title: "Audio Output", symbol: "speaker.wave.2",
                 keywords: ["sound", "speaker", "headphones", "airpods", "소리", "스피커", "이어폰", "출력"]) {
                .push(PaletteScreen(id: "audio-output", title: SystemStrings.localized("Audio Output")) {
                    AudioOutputView(model: audio).padding(24)
                })
            },
            item("keep-awake-stop", title: "Stop keeping awake", symbol: "moon",
                 keywords: ["caffeine", "sleep", "잠자기", "방지", "끄기"]) {
                awake.stop() ? .dismiss : .notify(awake.error ?? SystemStrings.localized("Could not stop Keep Awake. Try again."))
            },
        ]
        if let mixer {
            items.append(item("audio-mixer", title: "App Audio", symbol: "slider.horizontal.3",
                              keywords: ["audio", "mixer", "volume", "sound", "app", "앱별", "오디오", "믹서", "볼륨", "음량", "출력"]) {
                .push(PaletteScreen(id: "audio-mixer", title: SystemStrings.localized("App Audio")) {
                    AudioControlsView(audio: audio, mixer: mixer).padding(24)
                })
            })
        }
        return items
    }

    private func item(_ id: String, title: String, symbol: String, keywords: [String],
                      run: @escaping @MainActor () async -> PaletteActionOutcome) -> PaletteItem {
        PaletteItem(candidate: SearchCandidate(id: "utilities:\(id)", title: SystemStrings.localized(title),
                                               section: SystemStrings.localized("Utilities"), keywords: keywords,
                                               searchAliases: SystemStrings.bilingual(title)),
                    icon: .symbol(symbol), actions: [PaletteAction(id: id, title: SystemStrings.localized(title), run: run)])
    }
}

extension SystemFeature {
    @MainActor
    static func utilityWidgets(awake: KeepAwakeModel, audio: AudioOutputModel, mixer: AudioMixerModel? = nil,
                               initialShowsApps: Bool = true) -> [NotchWidget] {
        [
            NotchWidget(id: "keep-awake", title: SystemStrings.localized("Keep Awake"), systemImage: "cup.and.saucer",
                        activity: { awake.isActive ? SystemStrings.localized("Keeping your Mac awake") : nil },
                        activityPriority: -10,
                        compactContent: {
                            AnyView(Group { if let deadline = awake.deadline { AwakeRemaining(deadline: deadline) } })
                        }) { _ in KeepAwakeView(model: awake) },
            NotchWidget(id: "audio-output", title: SystemStrings.localized(mixer == nil ? "Audio Output" : "Audio"), systemImage: "speaker.wave.2") { _ in
                if let mixer { AudioControlsView(audio: audio, mixer: mixer, initialShowsApps: initialShowsApps) }
                else { AudioOutputView(model: audio) }
            },
        ]
    }

    /// Deterministic previews with no power assertion or audio device writes.
    @MainActor
    public static func utilitySnapshotWidgets(state: String = "") -> [NotchWidget] {
        let awake = KeepAwakeModel(acquire: {}, release: {})
        if state == "keep-awake-active" { awake.start(minutes: 60) }
        let audio = AudioOutputModel(read: {
            AudioOutputSnapshot(devices: [.init(id: 1, name: "MacBook Pro Speakers"), .init(id: 2, name: "Studio Display"),
                                           .init(id: 3, name: "AirPods Pro")], selectedID: 1)
        }, select: { _ in }, observe: { _ in {} })
        audio.refresh()
        let mixer = AudioMixerModel(initial: MixerPreferences(rules: ["com.apple.Music": MixerRule(volume: 0.4), "com.apple.Safari": MixerRule(volume: 0.8, outputUID: "headphones"), "com.apple.QuickTimePlayerX": MixerRule(volume: 0.65)]), read: {
            MixerSnapshot(apps: [.init(id: "com.apple.Music", name: "Music", processIDs: [1], isPlaying: true),
                                 .init(id: "com.apple.Safari", name: "Safari", processIDs: [2], isPlaying: true),
                                 .init(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player", processIDs: [3], isPlaying: true)],
                          outputs: [.init(id: "speakers", objectID: 1, name: "MacBook Pro Speakers", sampleRate: 48000),
                                    .init(id: "headphones", objectID: 2, name: "AirPods Pro", sampleRate: 48000)], defaultOutputUID: "speakers")
        }, save: { _ in }, makeSession: { _, _, _ in SnapshotMixerSession() })
        mixer.setEnabled(state != "audio-disabled")
        return utilityWidgets(awake: awake, audio: audio, mixer: mixer, initialShowsApps: state != "audio-system")
    }
}

@MainActor private final class SnapshotMixerSession: MixerSession {
    var isApplied = true
    func setGain(_ gain: Float) {}
    func poll() throws {}
    func stop() {}
}
