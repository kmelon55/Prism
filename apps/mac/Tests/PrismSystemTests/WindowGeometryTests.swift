import CoreGraphics
import Testing
@testable import PrismSystem

/// Ported from the tests in `window_management.rs` and `window_management_portable.rs`.
struct WindowGeometryTests {
    let identity = WindowIdentity(pid: 1, element: 1)

    @Test func rightHalfCyclesStayOnTheRightWhenTheAppClampsGrowthAtScreenEdges() {
        for origin in [0.0, -1200.0] {
            for reverse in [false, true] {
                let work = CGRect(x: origin, y: 30, width: 1200, height: 900)
                let options = WindowOptions(reverseCycle: reverse)
                var frame = CGRect(x: origin + 100, y: 80, width: 500, height: 500)
                var previous: CycleStep?
                let widths: [CGFloat] = reverse ? [600, 800, 400] : [600, 400, 800]
                for step in 0..<12 {
                    let index = WindowGeometry.cycleIndex(previous: previous, window: identity, layout: .rightHalf, current: frame, enabled: true)
                    let target = WindowGeometry.configuredRect(.rightHalf, workArea: work, current: frame, options: options, cycleIndex: index)
                    let actual = WindowGeometry.apply(target, read: { frame }, resize: { rect in
                        frame.size = CGSize(width: min(rect.width, work.maxX - frame.minX), height: min(rect.height, work.maxY - frame.minY))
                    }, position: { rect in
                        frame.origin = CGPoint(x: min(rect.minX, work.maxX - frame.width), y: min(rect.minY, work.maxY - frame.height))
                    })
                    #expect(actual.width == widths[step % 3], "step \(step), reverse \(reverse)")
                    #expect(actual.maxX == work.maxX)
                    #expect(actual.minY == work.minY)
                    #expect(actual.height == work.height)
                    previous = CycleStep(window: identity, layout: .rightHalf, index: index, bounds: actual)
                }
            }
        }
    }

    @Test func frameApplicationKeepsActualAppConstraintsAndBoundsRetries() {
        let constrained = CGRect(x: 0, y: 0, width: 600, height: 600)
        var writes = 0
        let actual = WindowGeometry.apply(CGRect(x: 0, y: 0, width: 400, height: 600), read: { constrained },
                                          resize: { _ in writes += 1 }, position: { _ in })
        #expect(actual == constrained)
        #expect(writes == 2)
    }

    @Test func repeatedHalfCyclesAndResetsForOtherWindowsActionsAndManualMoves() {
        let work = CGRect(x: -1200, y: 30, width: 1200, height: 900)
        var previous: CycleStep?
        var current = CGRect(x: -1000, y: 100, width: 500, height: 400)
        for expected: CGFloat in [600, 400, 800, 600] {
            let index = WindowGeometry.cycleIndex(previous: previous, window: identity, layout: .leftHalf, current: current, enabled: true)
            current = WindowGeometry.configuredRect(.leftHalf, workArea: work, current: current, options: WindowOptions(), cycleIndex: index)
            #expect(current.width == expected)
            #expect(current.minX == work.minX)
            previous = CycleStep(window: identity, layout: .leftHalf, index: index, bounds: current)
        }
        #expect(WindowGeometry.cycleIndex(previous: previous, window: WindowIdentity(pid: 2, element: 1), layout: .leftHalf, current: current, enabled: true) == 0)
        #expect(WindowGeometry.cycleIndex(previous: previous, window: identity, layout: .rightHalf, current: current, enabled: true) == 0)
        #expect(WindowGeometry.cycleIndex(previous: previous, window: identity, layout: .leftHalf, current: current.offsetBy(dx: 10, dy: 0), enabled: true) == 0)
        #expect(WindowGeometry.cycleIndex(previous: previous, window: identity, layout: .leftHalf, current: current, enabled: false) == 0)
    }

    @Test func configuredGapsAreSharedAndReverseCycleChangesOrder() {
        let work = CGRect(x: 0, y: 25, width: 1200, height: 900)
        let options = WindowOptions(reverseCycle: true, gap: 12, edgeGap: 20)
        let left = WindowGeometry.configuredRect(.leftHalf, workArea: work, current: .zero, options: options, cycleIndex: 0)
        let right = WindowGeometry.configuredRect(.rightHalf, workArea: work, current: .zero, options: options, cycleIndex: 0)
        #expect(left.minX == 20)
        #expect(left.minY == 45)
        #expect(right.minX - left.maxX == 12)
        #expect(right.maxX == 1180)
        let large = WindowGeometry.configuredRect(.rightHalf, workArea: work, current: .zero, options: options, cycleIndex: 1)
        let small = WindowGeometry.configuredRect(.rightHalf, workArea: work, current: .zero, options: options, cycleIndex: 2)
        #expect(large.width > right.width && right.width > small.width)
        #expect(abs(large.maxX - 1180) < 0.01)
    }

    @Test func gapsAreNotAppliedToPositionCommands() {
        let work = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let options = WindowOptions(gap: 20)
        #expect(WindowGeometry.configuredRect(.maximize, workArea: work, current: .zero, options: options, cycleIndex: 0) == work)
        let quarter = WindowGeometry.configuredRect(.bottomRightQuarter, workArea: work, current: .zero, options: options, cycleIndex: 0)
        #expect(quarter == CGRect(x: 510, y: 410, width: 490, height: 390))
    }

    @Test func almostMaximizeUsesTheConfiguredFraction() {
        let work = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = WindowGeometry.configuredRect(.almostMaximize, workArea: work, current: .zero, options: WindowOptions(almostMaximize: 80), cycleIndex: 0)
        #expect(WindowGeometry.close(rect, CGRect(x: 100, y: 80, width: 800, height: 640)))
        #expect(abs(rect.width - 800) < 0.001 && abs(rect.minY - 80) < 0.001)
    }

    @Test func sizeEdgeAndDisplayCommandsPreserveUnaffectedGeometry() {
        let work = CGRect(x: 0, y: 25, width: 1200, height: 900)
        let current = CGRect(x: 100, y: 80, width: 400, height: 500)
        #expect(WindowGeometry.targetRect(.maximizeWidth, workArea: work, current: current) == CGRect(x: 0, y: 80, width: 1200, height: 500))
        #expect(WindowGeometry.targetRect(.maximizeHeight, workArea: work, current: current) == CGRect(x: 100, y: 25, width: 400, height: 900))
        #expect(WindowGeometry.targetRect(.moveRight, workArea: work, current: current) == CGRect(x: 800, y: 80, width: 400, height: 500))
        #expect(WindowGeometry.targetRect(.moveDown, workArea: work, current: current) == CGRect(x: 100, y: 425, width: 400, height: 500))
        #expect(WindowGeometry.targetRect(.lastFourth, workArea: work, current: current) == CGRect(x: 900, y: 25, width: 300, height: 900))
        let destination = CGRect(x: -800, y: 0, width: 800, height: 600)
        let moved = WindowGeometry.transfer(current, from: work, to: destination)
        #expect(moved.size == current.size)
        #expect(moved.minX >= -800 && moved.maxX <= 0)
        #expect(moved.minY >= 0 && moved.maxY <= 600)
    }

    @Test func reasonableSizeIsCenteredAndCapped() {
        let work = CGRect(x: 0, y: 0, width: 2560, height: 1600)
        #expect(WindowGeometry.targetRect(.reasonableSize, workArea: work, current: .zero) == CGRect(x: 767.5, y: 350, width: 1025, height: 900))
        let small = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(WindowGeometry.targetRect(.reasonableSize, workArea: small, current: .zero) == CGRect(x: 200, y: 160, width: 600, height: 480))
    }

    @Test func halfAndMaximizeActionsUseTheMonitorWorkArea() {
        let work = CGRect(x: 20, y: 40, width: 1200, height: 800)
        let current = CGRect(x: 0, y: 0, width: 500, height: 400)
        #expect(WindowGeometry.targetRect(.leftHalf, workArea: work, current: current) == CGRect(x: 20, y: 40, width: 600, height: 800))
        #expect(WindowGeometry.targetRect(.maximize, workArea: work, current: current) == work)
        #expect(WindowGeometry.targetRect(.rightHalf, workArea: work, current: current).minX == 620)
    }

    @Test func centerPreservesSizeUntilTheWindowExceedsTheWorkArea() {
        let work = CGRect(x: 0, y: 20, width: 1000, height: 700)
        #expect(WindowGeometry.targetRect(.center, workArea: work, current: CGRect(x: 0, y: 0, width: 600, height: 400))
            == CGRect(x: 200, y: 170, width: 600, height: 400))
        #expect(WindowGeometry.targetRect(.center, workArea: work, current: CGRect(x: 0, y: 0, width: 1400, height: 900))
            == CGRect(x: 0, y: 20, width: 1000, height: 700))
    }

    @Test func quarterAndThirdLayoutsUsePredictableScreenFractions() {
        let work = CGRect(x: 30, y: 20, width: 1200, height: 900)
        #expect(WindowGeometry.targetRect(.bottomRightQuarter, workArea: work, current: .zero) == CGRect(x: 630, y: 470, width: 600, height: 450))
        #expect(WindowGeometry.targetRect(.centerThird, workArea: work, current: .zero) == CGRect(x: 430, y: 20, width: 400, height: 900))
        #expect(WindowGeometry.targetRect(.rightTwoThirds, workArea: work, current: .zero) == CGRect(x: 430, y: 20, width: 800, height: 900))
        #expect(WindowGeometry.targetRect(.bottomCenterSixth, workArea: work, current: .zero) == CGRect(x: 430, y: 470, width: 400, height: 450))
        #expect(WindowGeometry.targetRect(.centerTwoThirds, workArea: work, current: .zero) == CGRect(x: 230, y: 20, width: 800, height: 900))
    }

    @Test func almostMaximizeKeepsAFivePercentMargin() {
        let work = CGRect(x: 0, y: 20, width: 1000, height: 800)
        #expect(WindowGeometry.targetRect(.almostMaximize, workArea: work, current: .zero) == CGRect(x: 50, y: 60, width: 900, height: 720))
    }

    @Test func restoredLayoutIsClampedAfterMonitorChanges() {
        let work = CGRect(x: 0, y: 20, width: 1000, height: 700)
        #expect(WindowGeometry.clamp(CGRect(x: 1800, y: -200, width: 1400, height: 900), to: work) == work)
        #expect(WindowGeometry.clamp(CGRect(x: 900, y: 600, width: 300, height: 200), to: work) == CGRect(x: 700, y: 520, width: 300, height: 200))
        #expect(WindowGeometry.clamp(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), to: work) == work)
    }

    @Test func selectsTheMonitorWithLargestOverlap() {
        let areas = [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 2560, height: 1440)]
        #expect(WindowGeometry.displayIndex(for: CGRect(x: -300, y: 200, width: 800, height: 600), in: areas) == 1)
        #expect(WindowGeometry.displayIndex(for: CGRect(x: -1600, y: 200, width: 800, height: 600), in: areas) == 0)
    }

    @Test func appKitFramesConvertToAccessibilityCoordinates() {
        // A 1440×900 primary display with a 25 pt menu bar, and a display above it.
        #expect(WindowManager.accessibilityRect(CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900) == CGRect(x: 0, y: 25, width: 1440, height: 875))
        #expect(WindowManager.accessibilityRect(CGRect(x: 0, y: 900, width: 1920, height: 1080), primaryHeight: 900) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }
}

struct PreviousLayoutsTests {
    @Test func previousLayoutsAreWindowSpecificAndConsumedOnce() {
        let first = WindowIdentity(pid: 10, element: 100)
        let second = WindowIdentity(pid: 10, element: 200)
        let firstBounds = CGRect(x: 10, y: 20, width: 300, height: 400)
        let secondBounds = CGRect(x: 50, y: 60, width: 700, height: 800)
        var layouts = PreviousLayouts()
        layouts.remember(first, firstBounds)
        layouts.remember(second, secondBounds)
        #expect(layouts.restoreBounds(first) == firstBounds)
        #expect(layouts.restoreBounds(second) == secondBounds)
        layouts.completeRestore(first)
        #expect(layouts.restoreBounds(first) == nil)
        #expect(layouts.restoreBounds(second) == secondBounds)
    }

    @Test func failedLayoutBeforeGeometryChangePreservesTheEarlierCheckpoint() {
        let window = WindowIdentity(pid: 42, element: 9001)
        let original = CGRect(x: 1, y: 2, width: 3, height: 4)
        var layouts = PreviousLayouts()
        layouts.remember(window, original)
        let replaced = layouts.remember(window, CGRect(x: 10, y: 20, width: 30, height: 40))
        layouts.rollback(window, to: replaced)
        #expect(layouts.restoreBounds(window) == original)
    }

    @Test func staleLayoutHistoryIsBounded() {
        var layouts = PreviousLayouts()
        for token in 0...PreviousLayouts.capacity {
            layouts.remember(WindowIdentity(pid: 99, element: UInt(token)), CGRect(x: Double(token), y: 0, width: 0, height: 0))
        }
        #expect(layouts.frames.count == PreviousLayouts.capacity)
        #expect(layouts.restoreBounds(WindowIdentity(pid: 99, element: 0)) == nil)
        #expect(layouts.restoreBounds(WindowIdentity(pid: 99, element: UInt(PreviousLayouts.capacity))) != nil)
    }
}

struct WindowLayoutTests {
    @Test func actionParserAcceptsFrontendFriendlyAliases() {
        #expect(WindowLayout(parsing: "left-half") == .leftHalf)
        #expect(WindowLayout(parsing: "right_half") == .rightHalf)
        #expect(WindowLayout(parsing: "maximise") == .maximize)
        #expect(WindowLayout(parsing: "restore") == .restorePreviousLayout)
        #expect(WindowLayout(parsing: "restore_previous_layout")?.rawValue == "restore-previous-layout")
        #expect(WindowLayout(parsing: "window:next-display") == .nextDisplay)
        #expect(WindowLayout(parsing: "tile-thirds") == nil)
    }

    @Test func commandIDsMatchTheTauriCatalog() {
        let ids = WindowLayout.allCases.map(\.commandID)
        #expect(ids.count == 37)
        #expect(Set(ids).count == ids.count)
        for id in ["window:left-half", "window:right-half", "window:top-left-quarter", "window:bottom-center-sixth",
                   "window:center-two-thirds", "window:maximize", "window:almost-maximize", "window:center",
                   "window:maximize-width", "window:reasonable-size", "window:last-fourth", "window:move-up",
                   "window:next-display", "window:previous-display", "window:restore-previous-layout"] {
            #expect(ids.contains(id), "\(id)")
        }
    }

    @Test func everyLayoutHasAKoreanTitle() {
        for layout in WindowLayout.allCases {
            #expect(SystemStrings.bilingual(layout.englishTitle).count == 2, "\(layout)")
        }
    }
}
