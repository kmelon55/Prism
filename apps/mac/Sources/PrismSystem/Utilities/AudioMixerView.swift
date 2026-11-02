import AppKit
import PrismKit
import SwiftUI

struct AudioControlsView: View {
    let audio: AudioOutputModel
    @Bindable var mixer: AudioMixerModel
    @ViewState private var showApps = true
    @ViewState private var showInfo = false

    init(audio: AudioOutputModel, mixer: AudioMixerModel, initialShowsApps: Bool = true) {
        self.audio = audio; self.mixer = mixer
        _showApps = ViewState(initialValue: initialShowsApps)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                NotchModePicker([SystemStrings.localized("Apps"), SystemStrings.localized("System output")],
                                selection: Binding(get: { showApps ? 0 : 1 }, set: { showApps = $0 == 0 }))
                Spacer(minLength: 0)
                if showApps {
                    NotchIconButton("info", label: SystemStrings.localized("About app audio")) { showInfo.toggle() }
                        .popover(isPresented: $showInfo) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(SystemStrings.localized("App Audio")).font(.headline)
                                Text(SystemStrings.localized("Control each app's volume and output. macOS asks for System Audio Recording access when you first adjust an app. Audio stays on your Mac and is never saved."))
                                Text(SystemStrings.localized("Turn off to restore normal app audio."))
                            }.font(.system(size: 12)).padding(16).frame(width: 280)
                        }
                    Toggle(SystemStrings.localized("Enable app audio"), isOn: Binding(get: { mixer.enabled }, set: { mixer.setEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(.orange).disabled(!mixer.supported)
                }
            }.frame(height: 30)
            if showApps { AudioMixerView(model: mixer) }
            else { AudioOutputView(model: audio, showsHeading: false) }
        }
    }
}

struct AudioMixerView: View {
    @Bindable var model: AudioMixerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.supported {
                NotchEmptyState("speaker.slash", title: SystemStrings.localized("App audio requires macOS 14.2 or later."))
            } else if model.apps.isEmpty {
                NotchEmptyState("waveform", title: SystemStrings.localized("No audio playing"),
                                detail: SystemStrings.localized("Play audio in an app to see it here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.apps) { app in AudioMixerRow(model: model, app: app) }
                    }
                }.scrollIndicators(.automatic).frame(minHeight: 58)
            }
            if let error = model.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2).help(error)
            } else if !model.enabled, model.supported {
                Label(SystemStrings.localized("Turn on to adjust app audio."), systemImage: "slider.horizontal.3")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}

private struct AudioMixerRow: View {
    @Bindable var model: AudioMixerModel
    let app: MixerApp
    @ViewState private var draft = 1.0
    @ViewState private var editing = false
    @ViewState private var appPath: String?
    private var rule: MixerRule { model.rule(for: app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Group {
                    if let appPath { PrismFileIcon(path: appPath) }
                    else { Image(systemName: "app.fill").font(.system(size: 24)).foregroundStyle(.secondary) }
                }.frame(width: 28, height: 28).accessibilityHidden(true)
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if model.applied.contains(app.id) {
                            Circle().fill(.green).frame(width: 4, height: 4).help(SystemStrings.localized("Applied"))
                        }
                        Spacer(minLength: 4)
                        routeMenu.disabled(!model.enabled)
                        Menu {
                            Button(SystemStrings.localized("Restore normal audio")) { model.reset(app.id) }
                            if model.failures[app.id] != nil {
                                Button(SystemStrings.localized("Retry app audio")) { model.retry(app.id) }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 22).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(SystemStrings.localized("App audio actions"))
                    }
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { editing ? draft : rule.volume }, set: { draft = $0; editing = true }),
                               in: 0...1, onEditingChanged: { active in
                            if active { draft = rule.volume; editing = true }
                            else { editing = false; model.change(app.id) { $0.volume = draft } }
                        })
                        .controlSize(.small).tint(.orange).frame(height: 22)
                        .accessibilityLabel(app.name + " " + SystemStrings.localized("Volume"))
                        Text("\(Int((editing ? draft : rule.volume) * 100))%")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                        Button { model.change(app.id) { $0.muted.toggle() } } label: {
                            Image(systemName: rule.muted ? "speaker.slash.fill" : "speaker.wave.2")
                                .font(.system(size: 11)).frame(width: 24, height: 22)
                        }.buttonStyle(NotchButtonStyle(selected: rule.muted))
                            .help(SystemStrings.localized(rule.muted ? "Unmute app" : "Mute app"))
                            .accessibilityLabel(app.name + " " + SystemStrings.localized(rule.muted ? "Unmute app" : "Mute app"))
                    }.disabled(!model.enabled)
                }
            }
            if let failure = model.failures[app.id] {
                Text(failure).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).help(failure)
            } else if model.enabled, rule.isCustomized, !model.applied.contains(app.id) {
                Text(SystemStrings.localized("Waiting for audio and permission. Original playback is unchanged."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .task(id: app.id) { appPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)?.path }
    }

    private var routeMenu: some View {
        Menu {
            Button(SystemStrings.localized("Follow system output")) { model.change(app.id) { $0.outputUID = nil } }
            ForEach(model.outputs) { output in
                Button(output.name) { model.change(app.id) { $0.outputUID = output.id } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(rule.outputUID.flatMap { uid in model.outputs.first { $0.id == uid }?.name } ??
                     SystemStrings.localized(rule.outputUID == nil ? "System" : "Disconnected")).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }.font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: 150, alignment: .trailing).frame(height: 22)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: true, vertical: false)
            .help(SystemStrings.localized("Output for this app"))
    }
}
