import AppKit
import Testing
@testable import PrismNotch

private let displayA = NotchDisplay(id: "stable-a", number: 1, name: "Built-in",
                                  frame: CGRect(x: -20000, y: -20000, width: 1512, height: 982),
                                  cameraWidth: 180, topInset: 34, isBuiltIn: true, isMain: true)
private let displayB = NotchDisplay(id: "stable-b", number: 2, name: "External",
                                  frame: CGRect(x: -22000, y: -19000, width: 1920, height: 1080))
private let displayC = NotchDisplay(id: "stable-c", number: 3, name: "Portrait",
                                  frame: CGRect(x: -19000, y: -21000, width: 900, height: 1600))

struct NotchDisplaySelectionTests {
    @Test func mainAllAndExplicitSelectionsHaveDifferentReconnectBehavior() {
        let connected = [displayA, displayB]
        #expect(NotchDisplays().resolve(in: connected).map(\.id) == [displayA.id])
        #expect(NotchDisplays(mode: .all).resolve(in: connected + [displayC]).count == 3)
        var choice = NotchDisplays()
        choice.set(displayB.target, selected: true, connected: connected)
        #expect(choice.resolve(in: connected + [displayC]).map(\.id) == [displayA.id, displayB.id])
        choice.set(displayA.target, selected: false, connected: connected)
        #expect(choice.resolve(in: [displayA]).isEmpty) // Never move onto an unchecked screen.
        #expect(choice.targets == [displayB.target]) // Remember offline selection.
        let reconnected = NotchDisplay(id: displayB.id, number: 99, name: displayB.name, frame: displayB.frame)
        #expect(choice.resolve(in: [displayA, reconnected]).map(\.number) == [99])
        choice.set(displayB.target, selected: false, connected: connected)
        #expect(choice.resolve(in: connected).isEmpty)
    }

    @Test func uncheckingOneDisplayLeavesAllModeAndKeepsTheOthers() {
        var choice = NotchDisplays(mode: .all)
        choice.set(displayB.target, selected: false, connected: [displayA, displayB, displayC])
        #expect(choice.mode == .selected)
        #expect(choice.targets == [displayA.target, displayC.target])
    }

    @Test func oldSingleDisplaySettingsDecodeWithoutLosingTheTimer() throws {
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(NotchPreferences())) as? [String: Any])
        old.removeValue(forKey: "displays")
        old["screenID"] = 2
        old["enabled"] = true
        let state = try JSONDecoder().decode(NotchPreferences.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(state.enabled)
        #expect(state.displays.resolve(in: [displayA, displayB]).map(\.id) == [displayB.id])
        #expect(state.countdown == NotchCountdown())
        old.removeValue(forKey: "screenID")
        #expect(try JSONDecoder().decode(NotchPreferences.self, from: JSONSerialization.data(withJSONObject: old)).displays.mode == .main)
    }
}

@MainActor
struct NotchMultiDisplayTests {
    @Test func fullscreenPolicyFollowsEachDisplaysCutoutWithoutResettingTheTimer() throws {
        _ = NSApplication.shared
        var flatBuiltIn = displayB
        flatBuiltIn.isBuiltIn = true
        var connected = [displayA, flatBuiltIn]
        var initial = NotchPreferences()
        initial.enabled = true
        initial.displays = NotchDisplays(mode: .all)
        let model = NotchModel(widgets: [], initial: initial) { _ in }
        let controller = NotchController(model: model, displays: { connected }, rendersOffscreen: true)
        controller.start()
        defer { controller.stop() }
        let physical = try #require(controller.surfaces[displayA.id])
        let simulated = try #require(controller.surfaces[displayB.id])
        #expect(physical.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!physical.panel.collectionBehavior.contains(.fullScreenNone))
        #expect(simulated.panel.collectionBehavior.contains(.fullScreenNone))
        #expect(!simulated.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(simulated.panel.collectionBehavior.contains(.canJoinAllSpaces))

        let now = Date()
        model.startTimer(minutes: 25, now: now)
        let deadline = model.preferences.countdown.deadline
        // Reuse a panel after display metadata changes; do not leave the previous full-screen policy behind.
        connected[0].cameraWidth = 0
        connected[0].topInset = 0
        controller.reconcile()
        #expect(controller.surfaces[displayA.id] === physical)
        #expect(physical.panel.collectionBehavior.contains(.fullScreenNone))
        #expect(!physical.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(model.preferences.countdown.deadline == deadline)
        #expect(model.preferences.enabled)
    }

    @Test func panelsHaveIndependentPresentationAndOneSharedTimer() throws {
        _ = NSApplication.shared
        var initial = NotchPreferences()
        initial.enabled = true
        initial.displays = NotchDisplays(mode: .all)
        let model = NotchModel(widgets: [], initial: initial) { _ in }
        let controller = NotchController(model: model, displays: { [displayA, displayB] }, rendersOffscreen: true)
        controller.start()
        defer { controller.stop() }
        #expect(controller.surfaces.count == 2)
        let first = try #require(controller.surfaces[displayA.id])
        let second = try #require(controller.surfaces[displayB.id])
        #expect(first.panel.frame == displayA.geometry(active: false).stageFrame)
        #expect(second.panel.frame == displayB.geometry(active: false).stageFrame)
        #expect(controller.open(on: displayA.id))
        #expect(first.session.presentation.mode == .expanded)
        #expect(second.session.presentation.mode == .compact)
        first.session.presentation.togglePin()
        first.session.selection = "notes"
        #expect(controller.open(on: displayB.id))
        #expect(second.session.selection == "timer")
        controller.clickedOutside(window: second.panel)
        #expect(first.session.presentation.isPinned)
        #expect(second.session.presentation.mode == .expanded)
        controller.clickedOutside(window: nil)
        #expect(first.session.presentation.mode == .expanded)
        #expect(second.session.presentation.mode == .compact)
        let now = Date(timeIntervalSince1970: 1000)
        var completions = 0
        model.onTimerFinished = { completions += 1 }
        model.startTimer(minutes: 1, now: now)
        model.refreshTimer(now: now.addingTimeInterval(61))
        model.refreshTimer(now: now.addingTimeInterval(62))
        #expect(completions == 1)
        #expect(model.preferences.countdown.phase == .finished)
        #expect(controller.surfaces[displayA.id] === first)
        #expect(controller.surfaces[displayB.id] === second)
        controller.close(on: displayA.id)
        #expect(!first.session.presentation.isPinned)
    }

    @Test func unplugDeselectDisableAndLockDisposeEveryNativeSurface() throws {
        _ = NSApplication.shared
        var connected = [displayA, displayB]
        var initial = NotchPreferences()
        initial.enabled = true
        initial.displays = NotchDisplays(mode: .selected, targets: connected.map(\.target))
        let model = NotchModel(widgets: [], initial: initial) { _ in }
        let controller = NotchController(model: model, displays: { connected }, rendersOffscreen: true)
        controller.start()
        defer { controller.stop() }
        let removed = try #require(controller.surfaces[displayB.id])
        connected = [displayA]
        controller.reconcile()
        #expect(controller.surfaces.count == 1)
        #expect(!removed.panel.isVisible)
        #expect(removed.canvas.host == nil)
        #expect(model.preferences.displays.targets.contains(displayB.target))
        connected = [displayA, displayB]
        controller.reconcile()
        #expect(controller.surfaces.count == 2)
        #expect(controller.surfaces[displayB.id] !== removed)
        model.setDisplay(displayA.target, selected: false, connected: connected)
        #expect(controller.surfaces.keys.sorted() == [displayB.id])
        controller.open(on: displayB.id)
        controller.suspend()
        #expect(controller.surfaces.isEmpty)
        #expect(!controller.open())
        controller.resume()
        #expect(controller.surfaces[displayB.id]?.session.presentation.mode == .compact)
        model.setEnabled(false)
        #expect(controller.surfaces.isEmpty)
    }

    @Test func legacyDisplayIDUpgradesToUUIDAndSurvivesSaving() throws {
        var initial = NotchPreferences()
        initial.displays = NotchDisplays(mode: .selected, targets: [.init(id: "legacy:2", name: "")])
        var saved: NotchPreferences?
        let model = NotchModel(widgets: [], initial: initial) { saved = $0 }
        model.upgradeDisplayIDs(using: [displayA])
        #expect(saved == nil)
        model.upgradeDisplayIDs(using: [displayA, displayB])
        #expect(model.preferences.displays.targets == [displayB.target])
        let encoded = try JSONEncoder().encode(#require(saved))
        #expect(try JSONDecoder().decode(NotchPreferences.self, from: encoded).displays.targets == [displayB.target])
    }
}
