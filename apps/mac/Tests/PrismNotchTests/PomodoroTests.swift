import Foundation
import PrismKit
import SwiftUI
import Testing
@testable import PrismNotch

@MainActor
struct PomodoroTests {
    @Test func fourFocusSessionsLeadToLongBreakWithoutAutomaticallyStartingIt() {
        let model = NotchModel(widgets: []) { _ in }
        var now = Date()
        model.startPomodoro(now: now)
        var notifications = 0
        model.onTimerFinished = { notifications += 1 }
        for round in 1...4 {
            #expect(model.preferences.pomodoro?.stage == .focus)
            now += 1500
            model.refreshTimer(now: now)
            model.refreshTimer(now: now + 10)
            #expect(model.preferences.pomodoro?.completed == round)
            #expect(model.preferences.countdown.phase == .finished)
            #expect(notifications == round * 2 - 1)
            model.nextPomodoro(now: now)
            #expect(model.preferences.pomodoro?.stage == (round == 4 ? .longBreak : .shortBreak))
            #expect(model.preferences.countdown.duration == (round == 4 ? 900 : 300))
            now += round == 4 ? 900 : 300
            model.refreshTimer(now: now)
            model.nextPomodoro(now: now)
        }
        #expect(model.preferences.pomodoro?.completed == 0)
        #expect(model.preferences.pomodoro?.stage == .focus)
    }

    @Test func pauseAtDeadlineCountsOnceAndCannotReplaceAnActiveTimer() {
        let now = Date()
        let model = NotchModel(widgets: []) { _ in }
        model.startPomodoro(now: now)
        model.startTimer(minutes: 5, now: now)
        #expect(model.preferences.countdown.duration == 1500)
        model.pauseTimer(now: now + 1500)
        model.refreshTimer(now: now + 1600)
        #expect(model.preferences.pomodoro?.completed == 1)
        model.cancelTimer()
        #expect(model.preferences.pomodoro == nil)
        model.startTimer(minutes: 5, now: now)
        #expect(model.preferences.countdown.duration == 300)
    }

    @Test func pausedSessionAndOverdueCompletionSurviveRestart() throws {
        let now = Date()
        var saved = NotchPreferences()
        let model = NotchModel(widgets: []) { saved = $0 }
        model.startPomodoro(now: now)
        model.pauseTimer(now: now + 60)
        let decoded = try JSONDecoder().decode(NotchPreferences.self, from: JSONEncoder().encode(saved))
        let restored = NotchModel(widgets: [], initial: decoded) { saved = $0 }
        #expect(restored.preferences.countdown.phase == .paused)
        #expect(restored.preferences.countdown.remaining(at: now + 9000) == 1440)
        restored.resumeTimer(now: now + 9000)
        restored.refreshTimer(now: now + 11000)
        let recovered = NotchModel(widgets: [], initial: saved) { _ in }
        recovered.refreshTimer(now: now + 12000)
        #expect(recovered.preferences.countdown.phase == .finished)
        #expect(recovered.preferences.pomodoro?.completed == 1)
    }

    @Test func failedCompletionWriteDoesNotCountOrNotifyUntilItCanPersist() {
        let now = Date()
        var fails = false, notifications = 0
        let model = NotchModel(widgets: []) { _ in if fails { throw CocoaError(.fileWriteNoPermission) } }
        model.onTimerFinished = { notifications += 1 }
        model.startPomodoro(now: now)
        fails = true
        model.refreshTimer(now: now + 1500)
        #expect(model.preferences.pomodoro?.completed == 0)
        #expect(notifications == 0)
        fails = false
        model.refreshTimer(now: now + 1501)
        #expect(model.preferences.pomodoro?.completed == 1)
        #expect(notifications == 1)
    }

    @Test func legacySettingsDecodeWithoutPomodoro() throws {
        let data = try JSONEncoder().encode(NotchPreferences())
        let decoded = try JSONDecoder().decode(NotchPreferences.self, from: data)
        #expect(decoded.pomodoro == nil)
        #expect(decoded.isValid)
    }

    @Test func passiveStatusCannotHideTimerCompletion() {
        let passive = NotchWidget(id: "awake", title: "Awake", systemImage: "cup.and.saucer", activity: { "awake" },
                                  activityPriority: -10) { _ in EmptyView() }
        let recorder = NotchWidget(id: "record", title: "Record", systemImage: "mic", activity: { "recording" }) { _ in EmptyView() }
        let model = NotchModel(widgets: [passive, recorder]) { _ in }
        model.setWidget("awake", visible: true)
        #expect(model.activeWidget?.id == "awake")
        let now = Date()
        model.startPomodoro(now: now)
        #expect(model.activeWidget == nil)
        model.setWidget("record", visible: true)
        #expect(model.activeWidget?.id == "record")
        model.refreshTimer(now: now + 1500)
        #expect(model.activeWidget == nil)
    }
}
