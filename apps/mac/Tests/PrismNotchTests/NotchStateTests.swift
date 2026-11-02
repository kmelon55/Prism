import Foundation
import SwiftUI
import Testing
@testable import PrismNotch

struct NotchStateTests {
    @Test func closingUnderThePointerDoesNotImmediatelyReopen() {
        var state = NotchPresentation()
        state.preview()
        #expect(state.mode == .preview)
        state.toggle()
        #expect(state.mode == .expanded)
        state.close()
        state.preview()
        #expect(state.mode == .compact)
        state.leave()
        state.preview()
        #expect(state.mode == .preview)
    }

    @Test func previewLeavesButDeliberatelyOpenedToolsStayOpen() {
        var state = NotchPresentation()
        state.preview()
        state.leave()
        #expect(state.mode == .compact)
        state.open()
        state.leave()
        #expect(state.mode == .expanded)
        state.outsideClick()
        #expect(state.mode == .compact)
    }

    @Test func pinnedToolsIgnoreOutsideClicksButCanAlwaysBeClosed() {
        var state = NotchPresentation()
        state.togglePin()
        state.leave()
        state.outsideClick()
        #expect(state.mode == .expanded)
        #expect(state.isPinned)
        state.close()
        #expect(state.mode == .compact)
        #expect(!state.isPinned)
    }

    @Test func timerTracksElapsedTimeThroughSleepAndCompletesOnce() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = NotchCountdown()
        timer.start(minutes: 25, now: start)
        #expect(timer.remaining(at: start.addingTimeInterval(100)) == 1_400)
        let restored = try JSONDecoder().decode(NotchCountdown.self, from: JSONEncoder().encode(timer))
        timer = restored
        let finished = timer.finishIfNeeded(now: start.addingTimeInterval(2_000))
        #expect(finished)
        #expect(timer.phase == .finished)
        let finishedAgain = timer.finishIfNeeded(now: start.addingTimeInterval(2_001))
        #expect(!finishedAgain)
        #expect(timer.remaining(at: start.addingTimeInterval(2_001)) == 0)
    }

    @Test func pausedTimerDoesNotCountTimeUntilResumed() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = NotchCountdown()
        timer.start(minutes: 5, now: start)
        timer.pause(now: start.addingTimeInterval(100))
        #expect(timer.phase == .paused)
        #expect(timer.remaining(at: start.addingTimeInterval(10_000)) == 200)
        timer.resume(now: start.addingTimeInterval(10_000))
        #expect(timer.remaining(at: start.addingTimeInterval(10_040)) == 160)
        timer.cancel()
        #expect(timer.phase == .idle)
        #expect(timer.deadline == nil)
    }

    @Test func pauseAtTheDeadlineFinishesInsteadOfCreatingAnEmptyPause() {
        let now = Date(timeIntervalSince1970: 1_000)
        var timer = NotchCountdown()
        timer.start(minutes: 1, now: now)
        timer.pause(now: now.addingTimeInterval(60))
        #expect(timer.phase == .finished)
        #expect(timer.isValid)
    }

    @Test func malformedOrUnsupportedPersistedStateIsRejected() {
        var state = NotchPreferences()
        state.countdown.phase = .running
        #expect(!state.isValid)
        state.countdown.start(minutes: 1, now: .now)
        #expect(state.isValid)
        state.countdown.duration = .infinity
        #expect(!state.isValid)
        state = NotchPreferences()
        state.version = 2
        #expect(!state.isValid)
    }

    @Test func timerDurationIsBounded() {
        var timer = NotchCountdown()
        timer.start(minutes: -5, now: .now)
        #expect(timer.duration == 60)
        timer.start(minutes: Int.max, now: .now)
        #expect(timer.duration == 10_800)
    }

    @Test func movingTheClockBackDoesNotOverflowTheCountdownDisplay() {
        var timer = NotchCountdown()
        timer.start(minutes: 25, now: Date(timeIntervalSince1970: 10_000))
        #expect(timer.remaining(at: Date(timeIntervalSince1970: 0)) == 1_500)
        #expect(TimerLabel.time(.infinity) == "00:00")
        #expect(TimerLabel.time(60.1) == "01:01")
    }

    @Test func geometryUsesEachDisplaysOriginAndKeepsTheTopEdgeFixed() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: -1920, y: 400, width: 1920, height: 1080), cameraWidth: 180, topInset: 37)
        for mode in [NotchPresentation.Mode.compact, .preview, .expanded] {
            let frame = geometry.frame(mode: mode)
            #expect(frame.midX == -960)
            #expect(frame.maxY == 1480)
            #expect(geometry.screenFrame.contains(frame))
        }
        #expect(geometry.headerHeight == 37)
        #expect(geometry.compactWidth == geometry.cameraWidth + 20)
    }

    @Test func aDisplayWithoutACameraStaysAttachedAndNarrowScreensFit() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 300, y: -800, width: 400, height: 800))
        #expect(geometry.frame(mode: .compact).maxY == 0)
        #expect(geometry.frame(mode: .expanded).width == 376)
        #expect(geometry.screenFrame.contains(geometry.frame(mode: .expanded)))
    }

    @Test func activityMakesRoomBesideTheCameraWithoutMovingTheTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let idle = NotchGeometry(screenFrame: screen, cameraWidth: 180, topInset: 34)
        let active = NotchGeometry(screenFrame: screen, cameraWidth: 180, topInset: 34, showsActivity: true)
        #expect(active.compactWidth > idle.compactWidth)
        #expect(active.frame(mode: .compact).maxY == idle.frame(mode: .compact).maxY)
        #expect(active.frame(mode: .compact).midX == idle.frame(mode: .compact).midX)
        #expect(idle.frame(mode: .preview).width < idle.frame(mode: .expanded).width)
    }

    @Test func outlineHasConcaveShouldersAndKeepsTheCameraCovered() {
        for size in [CGSize(width: 200, height: 34), CGSize(width: 400, height: 106), CGSize(width: 480, height: 330)] {
            let path = NotchOutline().path(in: CGRect(origin: .zero, size: size))
            #expect(path.contains(CGPoint(x: 1, y: 0.01)))
            #expect(!path.contains(CGPoint(x: 1, y: 10)))
            #expect(path.contains(CGPoint(x: size.width / 2, y: 1)))
            #expect(path.contains(CGPoint(x: size.width / 2, y: size.height - 1)))
            #expect(path.contains(CGPoint(x: size.width / 2 - 89, y: 20)))
            #expect(path.contains(CGPoint(x: size.width / 2 + 89, y: 20)))
        }
    }
}
