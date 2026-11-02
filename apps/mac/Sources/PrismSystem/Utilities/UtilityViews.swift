import PrismKit
import SwiftUI

struct KeepAwakeView: View {
    @Bindable var model: KeepAwakeModel
    @ViewState private var minutes = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(SystemStrings.localized(model.isActive ? "Keeping your Mac awake" : "Keep Awake"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: model.isActive ? "circle.fill" : "moon")
                    .font(.system(size: model.isActive ? 5 : 11)).foregroundStyle(model.isActive ? .orange : .secondary)
            }
            HStack(spacing: 18) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 31, weight: .light)).foregroundStyle(.orange)
                    .frame(width: 68, height: 68)
                    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 4) {
                    if let deadline = model.deadline {
                        AwakeRemaining(deadline: deadline, size: 34)
                    } else {
                        Text(String(format: SystemStrings.localized("%lld min"), Int64(minutes)))
                            .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                    }
                    Text(SystemStrings.localized(model.isActive ? "Until normal sleep resumes" : "No automatic sleep"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.frame(maxHeight: .infinity)
            if model.isActive {
                Button { model.stop() } label: {
                    Label(SystemStrings.localized("Stop keeping awake"), systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 34)
                }.buttonStyle(NotchButtonStyle(selected: true))
            } else {
                HStack(spacing: 6) {
                    ForEach([25, 60, 120], id: \.self) { value in
                        Button { minutes = value } label: {
                            Text(String(format: SystemStrings.localized("%lld min"), Int64(value)))
                                .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 34)
                        }.buttonStyle(NotchButtonStyle(selected: minutes == value))
                    }
                    Button { model.start(minutes: minutes) } label: {
                        Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold)).frame(width: 42, height: 34)
                    }.buttonStyle(NotchButtonStyle(prominent: true))
                        .help(SystemStrings.localized("Start keeping awake")).accessibilityLabel(SystemStrings.localized("Start keeping awake"))
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.system(size: 10)).lineLimit(2).help(error)
            } else {
                Label(SystemStrings.localized("Closing the lid still puts your Mac to sleep."), systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .help(SystemStrings.localized("Prevents automatic sleep. Your display can turn off, and closing the lid or choosing Sleep still works."))
            }
        }
    }
}

struct AwakeRemaining: View {
    let deadline: Date
    var size: CGFloat = 11
    var body: some View {
        TimelineView(.animation(minimumInterval: 1)) { timeline in
            let seconds = Int(max(0, min(10_800, ceil(deadline.timeIntervalSince(timeline.date)))))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: size, weight: size > 20 ? .light : .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct AudioOutputView: View {
    @Bindable var model: AudioOutputModel
    var showsHeading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeading {
                HStack {
                    Text(SystemStrings.localized("Audio Output")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    NotchIconButton("arrow.clockwise", label: SystemStrings.localized("Refresh audio outputs")) { model.refresh() }
                }
            }
            if model.devices.isEmpty {
                NotchEmptyState("speaker.slash", title: SystemStrings.localized("No audio outputs available."))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.devices) { device in
                            Button { model.choose(device.id) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: outputSymbol(device.name)).font(.system(size: 15))
                                        .foregroundStyle(model.selectedID == device.id ? .orange : .secondary).frame(width: 26)
                                    Text(device.name).lineLimit(1).fontWeight(model.selectedID == device.id ? .medium : .regular)
                                    Spacer(minLength: 0)
                                    if model.selectedID == device.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
                                }
                                .font(.system(size: 12)).padding(.horizontal, 12).frame(height: 44)
                            }.buttonStyle(NotchButtonStyle(selected: model.selectedID == device.id))
                                .accessibilityAddTraits(model.selectedID == device.id ? .isSelected : [])
                        }
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true) }
            Text(SystemStrings.localized("Default output for your Mac"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help(SystemStrings.localized("Changes the default playback output. Apps with their own output setting may keep using it."))
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private func outputSymbol(_ name: String) -> String {
        let name = name.lowercased()
        if name.contains("airpods") { return "airpodspro" }
        if name.contains("headphone") || name.contains("headset") { return "headphones" }
        if name.contains("display") || name.contains("hdmi") { return "display" }
        return "speaker.wave.2"
    }
}
