import AppKit
import PrismCore
import PrismKit
import SwiftUI

public enum NotchFeature {
    public static let settingsPaneID = "notch"
    @MainActor private static var snapshotModel: NotchModel?

    @MainActor
    public static func make(context: any PrismContext, widgets: [NotchWidget]) -> FeatureContribution {
        let model = NotchModel(widgets: widgets, url: context.paths.file("notch-v1.json"))
        let controller = NotchController(model: model, context: context)
        snapshotModel = model
        return FeatureContribution(
            providers: [NotchProvider(controller: controller)],
            settingsPanes: [SettingsPane(id: settingsPaneID, title: N("Notch"), systemImage: "menubar.dock.rectangle",
                                        order: 15, keywords: ["notch", "island", "widgets", "timer", "노치", "위젯", "타이머"]) {
                NotchSettingsView(model: model)
            }],
            start: { controller.start() })
    }

    /// An offscreen view of the real feature, without starting its panel, timers, or event monitors.
    @MainActor
    public static func snapshot(mode: String, widget: String = "timer", camera: Bool = true, active: Bool = false,
                                widgets: [NotchWidget]? = nil) -> AnyView {
        let original = snapshotModel
        let replacements = widgets ?? []
        let existing = original?.widgets ?? []
        let effectiveWidgets = existing.map { widget in replacements.first { $0.id == widget.id } ?? widget } +
            replacements.filter { replacement in !existing.contains { $0.id == replacement.id } }
        var preferences = NotchPreferences()
        preferences.widgets = ["timer"] + effectiveWidgets.map(\.id)
        let model = NotchModel(widgets: effectiveWidgets, initial: preferences) { _ in }
        let session = NotchDisplaySession()
        session.selection = widget.hasPrefix("pomodoro") ? "timer" : widget
        if !model.visibleIDs.contains(session.selection) { model.setWidget(session.selection, visible: true) }
        if widget.hasPrefix("pomodoro") {
            model.cancelTimer()
            let now = Date()
            model.startPomodoro(now: now.addingTimeInterval(widget == "pomodoro-finished" ? -1500 : -360))
            if widget == "pomodoro-finished" { model.refreshTimer(now: now, notify: false) }
        }
        if active { model.startTimer(minutes: 25) }
        if mode == "expanded" { session.presentation.open() }
        if mode == "preview" { session.presentation.preview() }
        let geometry = snapshotGeometry(camera: camera, active: active)
        let frame = geometry.frame(mode: session.presentation.mode)
        return AnyView(NotchView(model: model, session: session, geometry: geometry, mode: session.presentation.mode, motionDisabled: true)
            .frame(width: frame.width, height: frame.height).background(.black).clipShape(NotchOutline()))
    }

    public static func snapshotSize(mode: String, camera: Bool = true, active: Bool = false) -> CGSize {
        snapshotGeometry(camera: camera, active: active).frame(mode: mode == "expanded" ? .expanded : mode == "preview" ? .preview : .compact).size
    }

    private static func snapshotGeometry(camera: Bool, active: Bool) -> NotchGeometry {
        NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                      cameraWidth: camera ? 180 : 0, topInset: camera ? 34 : 0, showsActivity: active)
    }
}

@MainActor
private final class NotchProvider: PaletteProvider {
    let id = "notch"
    let controller: NotchController
    init(controller: NotchController) { self.controller = controller }

    func results(for query: String) async -> [PaletteItem] {
        [PaletteItem(candidate: SearchCandidate(id: "notch:open", title: N("Open Notch"),
                                                subtitle: N("Timers and your favorite tools at the top of your screen"),
                                                section: N("Productivity"),
                                                keywords: ["notch", "island", "widgets", "timer", "pomodoro", "focus", "노치", "위젯", "타이머", "뽀모도로", "포모도로", "집중"],
                                                searchAliases: ["Open Notch", "노치 열기"]),
                     icon: .symbol("menubar.dock.rectangle"), actions: [
                        PaletteAction(id: "open-notch", title: N("Open Notch")) { [controller] in
                            guard controller.open() else { return .notify(controller.model.error ?? N("Connect or select a display in Notch settings.")) }
                            if let error = controller.model.error { return .notify(error) }
                            return .dismiss
                        },
                     ]),
         PaletteItem(candidate: SearchCandidate(id: "notch:pomodoro", title: N("Start Pomodoro"),
                                                 subtitle: N("25-minute focus sessions with short and long breaks"), section: N("Productivity"),
                                                 keywords: ["pomodoro", "focus", "timer", "뽀모도로", "포모도로", "집중", "타이머"],
                                                 searchAliases: ["Start Pomodoro", "뽀모도로 시작"]),
                     icon: .symbol("timer"), actions: [
                        PaletteAction(id: "start-pomodoro", title: N("Start Pomodoro")) { [controller] in
                            guard controller.model.preferences.countdown.phase == .idle else {
                                return .notify(N("A timer is already active. Finish or cancel it first."))
                            }
                            guard controller.open(widget: "timer") else {
                                return .notify(controller.model.error ?? N("Connect or select a display in Notch settings."))
                            }
                            controller.model.startPomodoro()
                            if let error = controller.model.error { return .notify(error) }
                            return .dismiss
                        },
                     ])]
    }
}
