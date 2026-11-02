import Foundation
import PrismKit
import SwiftUI
import Testing
@testable import PrismNotch

@MainActor
struct NotchModelTests {
    private var widgets: [NotchWidget] {
        ["notes", "clipboard", "dictation"].map { id in
            NotchWidget(id: id, title: id, systemImage: "circle") { _ in EmptyView() }
        }
    }

    @Test func disabledByDefaultAndRemovingWidgetsDoesNotChangeTheirServices() {
        var saved: NotchPreferences?
        let model = NotchModel(widgets: widgets) { saved = $0 }
        #expect(!model.preferences.enabled)
        model.setWidget("notes", visible: false)
        #expect(!model.visibleIDs.contains("notes"))
        #expect(model.widgets.count == 3)
        #expect(saved?.widgets.contains("notes") == false)
        model.setWidget("notes", visible: true)
        #expect(model.visibleIDs.last == "notes")
        model.moveWidget("notes", by: -1)
        #expect(model.visibleIDs == ["timer", "clipboard", "notes", "dictation"])
        model.moveWidget("dictation", to: "timer")
        #expect(model.visibleIDs == ["dictation", "timer", "clipboard", "notes"])
        model.moveWidget("dictation", to: "notes")
        #expect(model.visibleIDs == ["timer", "clipboard", "notes", "dictation"])
        model.moveWidget("missing", to: "timer")
        #expect(model.visibleIDs == ["timer", "clipboard", "notes", "dictation"])
    }

    @Test func removingTheSelectedToolFallsBackWithoutDisplayingAnUnknownWidget() {
        let model = NotchModel(widgets: widgets) { _ in }
        model.setWidget("notes", visible: false)
        #expect(model.selectedID(for: "notes") == "timer")
        model.change { $0.widgets = ["missing", "timer", "timer"] }
        #expect(model.visibleIDs == ["timer"])
        model.setWidget("timer", visible: false)
        #expect(model.selectedID(for: "notes") == nil)
    }

    @Test func failedPersistenceDoesNotPretendASettingOrTimerWasSaved() {
        let model = NotchModel(widgets: widgets) { _ in throw CocoaError(.fileWriteNoPermission) }
        model.setEnabled(true)
        #expect(!model.preferences.enabled)
        #expect(model.error != nil)
        model.startTimer(minutes: 5)
        #expect(model.preferences.countdown.phase == .idle)
    }

    @Test func timerAndWidgetPreferencesSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notch.json")
        let now = Date(timeIntervalSince1970: 10_000)
        let original = NotchModel(widgets: widgets, url: url)
        original.setEnabled(true)
        original.setWidget("clipboard", visible: false)
        original.startTimer(minutes: 25, now: now)
        let restored = NotchModel(widgets: widgets, url: url)
        #expect(restored.preferences.enabled)
        #expect(!restored.visibleIDs.contains("clipboard"))
        #expect(restored.preferences.countdown.remaining(at: now.addingTimeInterval(300)) == 1200)
        var completed = 0
        restored.onTimerFinished = { completed += 1 }
        restored.refreshTimer(now: now.addingTimeInterval(1600))
        restored.refreshTimer(now: now.addingTimeInterval(1700))
        #expect(completed == 1)
        #expect(NotchModel(widgets: widgets, url: url).preferences.countdown.phase == .finished)
    }

    @Test func corruptFileIsPreservedAndTheNotchStaysOff() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("broken".utf8)
        try original.write(to: url)
        let model = NotchModel(widgets: widgets, url: url)
        #expect(model.error != nil)
        #expect(!model.preferences.enabled)
        #expect(try Data(contentsOf: url) == original)
    }
}
