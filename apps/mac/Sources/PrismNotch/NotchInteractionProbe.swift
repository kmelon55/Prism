import AppKit
import PrismKit
import SwiftUI

extension NotchFeature {
    /// Send events only to this process's invisible native panel, through the running NSApplication
    /// event loop. No global event injection, desktop capture, external accessibility or microphone.
    @MainActor public static func verifyInteractions(to url: URL) async throws {
        let display = NotchDisplay(id: "interaction-probe", number: 0, name: "Probe",
                                   frame: CGRect(x: -20000, y: -20000, width: 1512, height: 982),
                                   cameraWidth: 180, topInset: 34, isMain: true)
        var preferences = NotchPreferences()
        preferences.enabled = true
        let widgets = ["clipboard", "notes", "dictation"].map { id in
            NotchWidget(id: id, title: id, systemImage: "square") { _ in Text(id) }
        }
        let model = NotchModel(widgets: widgets, initial: preferences) { _ in }
        let controller = NotchController(model: model, displays: { [display] }, rendersOffscreen: true)
        controller.start()
        defer { controller.stop() }
        guard let surface = controller.surfaces[display.id] else { return }
        surface.panel.ignoresMouseEvents = false
        var checks: [[String: Any]] = []
        var mouseSequencesCaptured = true
        func check(_ name: String, _ success: Bool) { checks.append(["name": name, "passed": success]) }
        func click(x: CGFloat, y: CGFloat, hold: Double = 0.06) async {
            let point = surface.canvas.convert(CGPoint(x: (surface.canvas.contentFrame?.minX ?? 0) + x, y: y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: surface.panel.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(for: .seconds(type == .leftMouseDown ? hold : 0.10))
                mouseSequencesCaptured = mouseSequencesCaptured && (surface.panel.isHandlingPointer == (type == .leftMouseDown))
            }
        }
        try await Task.sleep(for: .milliseconds(650))
        controller.hover(true, on: display.id)
        await click(x: 100, y: 17, hold: 0.32)
        check("header-click-survives-hover-delay", surface.session.presentation.mode == .expanded)
        controller.open(on: display.id)
        try await Task.sleep(for: .milliseconds(650))
        await click(x: 109, y: 47)
        check("unselected-tab-padding", surface.session.selection == "clipboard")
        await click(x: 393, y: 53)
        check("pin-button-padding", surface.session.presentation.isPinned)
        for _ in 0..<3 {
            await click(x: 184, y: 47)
            check("notes-tab-padding", surface.session.selection == "notes")
            await click(x: 75, y: 47)
            check("clipboard-tab-padding", surface.session.selection == "clipboard")
        }
        await click(x: 34, y: 47)
        check("timer-tab-padding", surface.session.selection == "timer")
        try await Task.sleep(for: .milliseconds(250))
        await click(x: 426, y: 188)
        check("timer-start", model.preferences.countdown.phase == .running)
        await click(x: 393, y: 205)
        check("timer-pause", model.preferences.countdown.phase == .paused)
        await click(x: 393, y: 205)
        check("timer-resume", model.preferences.countdown.phase == .running)
        await click(x: 441, y: 205)
        check("timer-cancel", model.preferences.countdown.phase == .idle)
        await click(x: 427, y: 53)
        check("settings-button-padding", surface.session.presentation.mode == .compact)
        check("mouse-sequences-captured-through-release", mouseSequencesCaptured)
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
