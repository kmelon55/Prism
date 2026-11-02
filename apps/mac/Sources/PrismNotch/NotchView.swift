import PrismKit
import SwiftUI

struct NotchView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Bindable var model: NotchModel
    @Bindable var session = NotchDisplaySession()
    @Namespace private var tabs
    let geometry: NotchGeometry
    let mode: NotchPresentation.Mode
    var motionDisabled = false
    var toggle: @MainActor () -> Void = {}
    var open: @MainActor () -> Void = {}
    var close: @MainActor () -> Void = {}
    var settings: @MainActor () -> Void = {}
    private var selectedID: String? { model.selectedID(for: session.selection) }
    private var reduceMotion: Bool { systemReduceMotion || motionDisabled }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch mode {
            case .compact: EmptyView()
            case .preview: preview
            case .expanded: expanded
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .font(.system(size: 12))
        .environment(\.colorScheme, .dark)
        .buttonStyle(.plain)
        .onExitCommand(perform: close)
    }

    private var header: some View {
        Button(action: toggle) {
            ZStack {
                Color.clear
                if model.hasActivity {
                    HStack(spacing: 8) {
                        Image(systemName: model.activeWidget?.systemImage ?? "timer")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // No text or controls under the physical camera cutout.
                        Color.clear.frame(width: geometry.cameraWidth, height: 1)
                        compactStatus.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .frame(height: geometry.headerHeight)
            .contentShape(Rectangle())
        }
        .help(mode == .expanded ? N("Collapse notch") : N("Open notch"))
        .accessibilityLabel(mode == .expanded ? N("Collapse notch") : N("Open notch"))
    }

    @ViewBuilder private var compactStatus: some View {
        if let widget = model.activeWidget {
            if let compactContent = widget.compactContent {
                compactContent().frame(width: 36, height: 18)
            } else {
                Text(widget.activity() ?? widget.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
        } else if model.preferences.countdown.phase != .idle {
            TimerLabel(countdown: model.preferences.countdown)
                .foregroundStyle(model.preferences.countdown.phase == .finished ? .green : .orange)
        }
    }

    private var preview: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                if let widget = model.activeWidget {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(widget.activity() ?? widget.title).font(.system(size: 12, weight: .medium))
                        Text(widget.title).foregroundStyle(.secondary).font(.system(size: 10))
                    }
                } else {
                    HStack(spacing: 7) {
                        ForEach(model.visibleIDs.prefix(4), id: \.self) { id in
                            Image(systemName: model.symbol(for: id))
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                Text(N("Click to open")).foregroundStyle(.secondary).font(.system(size: 11))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(model.visibleIDs, id: \.self) { id in
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) { session.selection = id }
                            } label: {
                                HStack(spacing: 7) {
                                    NotchSymbol(model.symbol(for: id))
                                    if selectedID == id {
                                        Text(model.title(for: id)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, selectedID == id ? 11 : 9)
                                .frame(height: 32)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                                .background {
                                    if selectedID == id {
                                        RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.09))
                                            .matchedGeometryEffect(id: "selected-tool", in: tabs)
                                    }
                                }
                                .foregroundStyle(selectedID == id ? .white : .white.opacity(0.48))
                            }
                            .accessibilityAddTraits(selectedID == id ? .isSelected : [])
                            .accessibilityLabel(model.title(for: id))
                            .help(model.title(for: id))
                        }
                    }
                }
                .scrollIndicators(.never)
                NotchIconButton(session.presentation.isPinned ? "pin.fill" : "pin",
                                label: N("Keep open"), selected: session.presentation.isPinned) {
                    session.presentation.togglePin()
                }
                NotchIconButton("slider.horizontal.3", label: N("Customize notch"), action: settings)
            }
            .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 10)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 24)
            Group {
                if selectedID == "timer" {
                    NotchTimerView(model: model)
                } else if let widget = model.widgets.first(where: { $0.id == selectedID }) {
                    widget.content(close)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 24)).foregroundStyle(.secondary)
                        Text(N("Choose the tools you want here."))
                        Button(N("Customize notch"), action: settings).foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(selectedID)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.system(size: 10)).lineLimit(2)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
        }
        .frame(height: 296)
    }
}

struct TimerLabel: View {
    let countdown: NotchCountdown
    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: countdown.phase != .running)) { timeline in
            if countdown.phase == .finished {
                Image(systemName: "checkmark.circle.fill").accessibilityLabel(N("Timer finished"))
            } else {
                Text(Self.time(countdown.remaining(at: timeline.date)))
                    .monospacedDigit().font(.system(size: 11, weight: .medium))
            }
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        let value = seconds.isFinite ? Int(min(10_800, max(0, ceil(seconds)))) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct NotchTimerView: View {
    @Bindable var model: NotchModel
    @ViewState private var minutes = 25.0
    @ViewState private var wantsPomodoro = false
    private var countdown: NotchCountdown { model.preferences.countdown }
    private var pomodoro: NotchPomodoro? { model.preferences.pomodoro }
    private var headline: String {
        guard let pomodoro else { return N(countdown.phase == .finished ? "Time is up" : "A little time to focus") }
        switch pomodoro.stage {
        case .focus: return N(countdown.phase == .finished ? "Focus session complete" : "Time to focus")
        case .shortBreak, .longBreak: return N(countdown.phase == .finished ? "Break is over" : "Time for a break")
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                if countdown.phase == .idle {
                    NotchModePicker([N("Timer"), N("Pomodoro")],
                                    selection: Binding(get: { wantsPomodoro ? 1 : 0 }, set: { wantsPomodoro = $0 == 1 }))
                } else {
                    Label(N(pomodoro == nil ? "Timer" : "Pomodoro"), systemImage: pomodoro == nil ? "timer" : "circle.dotted")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if let pomodoro {
                    HStack(spacing: 5) {
                        ForEach(0..<4) { index in
                            Circle().fill(index < pomodoro.completed % 4 || pomodoro.completed == 4 ? Color.orange : .white.opacity(0.16))
                                .frame(width: 6, height: 6)
                        }
                    }.accessibilityLabel(String(format: N("%lld / 4 sessions"), Int64(pomodoro.completed)))
                }
                if countdown.phase == .paused {
                    Text(N("Paused")).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                }
            }.frame(height: 28)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.animation(minimumInterval: 1, paused: countdown.phase != .running)) { timeline in
                        Text(TimerLabel.time(countdown.phase == .idle ? (wantsPomodoro ? 25 : minutes) * 60 : countdown.remaining(at: timeline.date)))
                            .font(.system(size: 58, weight: .light, design: .rounded)).monospacedDigit()
                            .tracking(-1.8).contentTransition(.numericText(countsDown: true))
                    }
                    Text(headline).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                controls
            }.frame(maxHeight: .infinity)
            if countdown.phase == .idle && !wantsPomodoro {
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        ForEach([5, 15, 25, 50], id: \.self) { value in
                            Button { minutes = Double(value) } label: {
                                Text(String(format: N("%lld min"), Int64(value)))
                                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
                            }.buttonStyle(NotchButtonStyle(selected: minutes == Double(value)))
                        }
                    }
                    Slider(value: Binding(get: { minutes }, set: { minutes = $0.rounded() }), in: 1...180)
                        .controlSize(.small).tint(.orange).accessibilityLabel(N("Duration in minutes"))
                }
            } else if countdown.phase == .idle {
                HStack(spacing: 7) {
                    Label(N("25 min focus"), systemImage: "circle.dotted")
                    Image(systemName: "arrow.right").font(.system(size: 9))
                    Text(N("5 min break"))
                    Spacer()
                    Text(N("4 rounds")).foregroundStyle(.orange)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .help(N("Focus for 25 minutes, rest for 5. Take a 15-minute break after four sessions."))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.animation(minimumInterval: 1, paused: countdown.phase != .running)) { timeline in
                        GeometryReader { proxy in
                            let progress = min(1, max(0, 1 - countdown.remaining(at: timeline.date) / max(1, countdown.duration)))
                            Capsule().fill(.white.opacity(0.09))
                            Capsule().fill(countdown.phase == .finished ? Color.green : .orange)
                                .frame(width: proxy.size.width * progress)
                        }.frame(height: 4)
                    }
                    if countdown.phase == .finished, let next = pomodoro?.next {
                        Button { model.nextPomodoro() } label: {
                            HStack {
                                Text(N(next.stage == .focus ? "Start next focus session" : next.stage == .longBreak ? "Start 15-minute break" : "Start 5-minute break"))
                                Spacer()
                                Image(systemName: "arrow.right")
                            }.font(.system(size: 11, weight: .medium)).padding(10)
                        }.buttonStyle(NotchButtonStyle(selected: true))
                    } else {
                        Text(N(pomodoro == nil ? "Keeps time while the notch is closed or your Mac sleeps." : "Start each break and focus session when you are ready."))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            switch countdown.phase {
            case .idle:
                control("play.fill", wantsPomodoro ? "Start Pomodoro" : "Start timer") {
                    if wantsPomodoro { model.startPomodoro() } else { model.startTimer(minutes: Int(minutes)) }
                }
            case .running:
                control("pause.fill", "Pause timer") { model.pauseTimer() }
                control("xmark", "Cancel timer", primary: false) { model.cancelTimer() }
            case .paused:
                control("play.fill", "Resume timer") { model.resumeTimer() }
                control("xmark", "Cancel timer", primary: false) { model.cancelTimer() }
            case .finished:
                control("checkmark", "Dismiss timer") { model.cancelTimer() }
            }
        }
    }

    private func control(_ symbol: String, _ label: String, primary: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: primary ? 18 : 12, weight: .semibold))
                .frame(width: primary ? 50 : 30, height: primary ? 50 : 30)
        }.buttonStyle(NotchButtonStyle(prominent: primary)).help(N(label)).accessibilityLabel(N(label))
    }
}
