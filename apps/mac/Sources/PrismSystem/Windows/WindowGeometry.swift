import CoreGraphics

/// Window layout math, ported from `window_management.rs`. Rectangles use Accessibility coordinates:
/// the origin is the top-left corner of the primary display and y grows downward.
enum WindowGeometry {
    /// Writes within two points are treated as accepted; apps round sizes to their own increments.
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// Keeps `bounds` inside `workArea`, shrinking it only when it is larger than the work area.
    static func clamp(_ bounds: CGRect, to workArea: CGRect) -> CGRect {
        let values = [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
                      workArea.origin.x, workArea.origin.y, workArea.size.width, workArea.size.height]
        guard values.allSatisfy(\.isFinite), workArea.size.width > 0, workArea.size.height > 0 else { return workArea }
        let width = min(max(bounds.size.width, 1), workArea.size.width)
        let height = min(max(bounds.size.height, 1), workArea.size.height)
        return CGRect(
            x: min(max(bounds.origin.x, workArea.minX), workArea.minX + workArea.size.width - width),
            y: min(max(bounds.origin.y, workArea.minY), workArea.minY + workArea.size.height - height),
            width: width, height: height
        )
    }

    /// Moves a window to another display, keeping its size and relative position.
    static func transfer(_ current: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let relativeX = min(max((current.minX - source.minX) / max(source.width, 1), 0), 1)
        let relativeY = min(max((current.minY - source.minY) / max(source.height, 1), 0), 1)
        return clamp(CGRect(x: destination.minX + relativeX * destination.width,
                            y: destination.minY + relativeY * destination.height,
                            width: current.width, height: current.height), to: destination)
    }

    /// The display whose work area overlaps the window most. Stable for windows straddling displays.
    static func displayIndex(for bounds: CGRect, in areas: [CGRect]) -> Int {
        var best = 0
        var bestOverlap = -1.0
        for (index, area) in areas.enumerated() {
            let width = max(min(bounds.maxX, area.maxX) - max(bounds.minX, area.minX), 0)
            let height = max(min(bounds.maxY, area.maxY) - max(bounds.minY, area.minY), 0)
            if width * height > bestOverlap {
                bestOverlap = width * height
                best = index
            }
        }
        return best
    }

    /// Which step of the Left/Right Half size cycle to apply: 0 is a half, then a third and two thirds.
    static func cycleIndex(previous: CycleStep?, window: WindowIdentity, layout: WindowLayout, current: CGRect, enabled: Bool) -> Int {
        guard enabled, layout.cycles, let previous,
              previous.window == window, previous.layout == layout, close(previous.bounds, current) else { return 0 }
        return (previous.index + 1) % 3
    }

    /// The target frame including the configured edge gap, window gap, cycle step and almost-maximize size.
    static func configuredRect(_ layout: WindowLayout, workArea work: CGRect, current: CGRect, options: WindowOptions, cycleIndex index: Int) -> CGRect {
        let edge = min(Double(options.edgeGap), min(work.width, work.height) / 4)
        let area = CGRect(x: work.minX + edge, y: work.minY + edge, width: work.width - 2 * edge, height: work.height - 2 * edge)
        let mapped: WindowLayout = switch (layout, index, options.reverseCycle) {
        case (.leftHalf, 1, false), (.leftHalf, 2, true): .firstThird
        case (.leftHalf, 2, false), (.leftHalf, 1, true): .leftTwoThirds
        case (.rightHalf, 1, false), (.rightHalf, 2, true): .lastThird
        case (.rightHalf, 2, false), (.rightHalf, 1, true): .rightTwoThirds
        default: layout
        }
        if layout == .almostMaximize {
            let fraction = Double(options.almostMaximize) / 100
            return CGRect(x: area.minX + area.width * (1 - fraction) / 2, y: area.minY + area.height * (1 - fraction) / 2,
                          width: area.width * fraction, height: area.height * fraction)
        }
        var rect = targetRect(mapped, workArea: area, current: current)
        guard layout.receivesGap else { return rect }
        let inset = min(Double(options.gap), min(rect.width, rect.height) / 2) / 2
        let right = rect.maxX
        let bottom = rect.maxY
        if rect.minX > area.minX + 1 {
            rect.origin.x += inset
            rect.size.width -= inset
        }
        if right < area.maxX - 1 { rect.size.width -= inset }
        if rect.minY > area.minY + 1 {
            rect.origin.y += inset
            rect.size.height -= inset
        }
        if bottom < area.maxY - 1 { rect.size.height -= inset }
        return rect
    }

    /// The plain frame for a layout inside a work area, without gaps.
    static func targetRect(_ layout: WindowLayout, workArea work: CGRect, current: CGRect) -> CGRect {
        let halfWidth = work.width / 2
        let halfHeight = work.height / 2
        let third = work.width / 3
        func rect(x: Double = 0, y: Double = 0, width: Double? = nil, height: Double? = nil) -> CGRect {
            CGRect(x: work.minX + x, y: work.minY + y, width: width ?? work.width, height: height ?? work.height)
        }
        switch layout {
        case .maximizeWidth:
            let clamped = clamp(current, to: work)
            return CGRect(x: work.minX, y: clamped.minY, width: work.width, height: clamped.height)
        case .maximizeHeight:
            let clamped = clamp(current, to: work)
            return CGRect(x: clamped.minX, y: work.minY, width: clamped.width, height: work.height)
        case .reasonableSize:
            let width = min(work.width * 0.6, 1025)
            let height = min(work.height * 0.6, 900)
            return rect(x: (work.width - width) / 2, y: (work.height - height) / 2, width: width, height: height)
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth:
            let index: Double = switch layout {
            case .secondFourth: 1
            case .thirdFourth: 2
            case .lastFourth: 3
            default: 0
            }
            return rect(x: work.width * index / 4, width: work.width / 4)
        case .moveLeft:
            var moved = clamp(current, to: work)
            moved.origin.x = work.minX
            return moved
        case .moveRight:
            var moved = clamp(current, to: work)
            moved.origin.x = work.maxX - moved.width
            return moved
        case .moveUp:
            var moved = clamp(current, to: work)
            moved.origin.y = work.minY
            return moved
        case .moveDown:
            var moved = clamp(current, to: work)
            moved.origin.y = work.maxY - moved.height
            return moved
        case .nextDisplay, .previousDisplay, .restorePreviousLayout:
            return clamp(current, to: work)
        case .leftHalf: return rect(width: halfWidth)
        case .rightHalf: return rect(x: halfWidth, width: halfWidth)
        case .topHalf: return rect(height: halfHeight)
        case .bottomHalf: return rect(y: halfHeight, height: halfHeight)
        case .topLeftQuarter: return rect(width: halfWidth, height: halfHeight)
        case .topRightQuarter: return rect(x: halfWidth, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter: return rect(y: halfHeight, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter: return rect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight)
        case .topLeftSixth: return rect(width: third, height: halfHeight)
        case .topCenterSixth: return rect(x: third, width: third, height: halfHeight)
        case .topRightSixth: return rect(x: third * 2, width: third, height: halfHeight)
        case .bottomLeftSixth: return rect(y: halfHeight, width: third, height: halfHeight)
        case .bottomCenterSixth: return rect(x: third, y: halfHeight, width: third, height: halfHeight)
        case .bottomRightSixth: return rect(x: third * 2, y: halfHeight, width: third, height: halfHeight)
        case .firstThird: return rect(width: third)
        case .centerThird: return rect(x: third, width: third)
        case .lastThird: return rect(x: third * 2, width: third)
        case .leftTwoThirds: return rect(width: third * 2)
        case .centerTwoThirds: return rect(x: third / 2, width: third * 2)
        case .rightTwoThirds: return rect(x: third, width: third * 2)
        case .maximize: return work
        case .almostMaximize:
            let horizontal = work.width * 0.05
            let vertical = work.height * 0.05
            return rect(x: horizontal, y: vertical, width: work.width - horizontal * 2, height: work.height - vertical * 2)
        case .center:
            return CGRect(x: work.minX + max((work.width - current.width) / 2, 0), y: work.minY + max((work.height - current.height) / 2, 0),
                          width: min(current.width, work.width), height: min(current.height, work.height))
        }
    }

    /// Applies a frame through separate size and position writes. Some apps acknowledge a resize but clamp it to
    /// the space left at the current position, so the window first moves toward the target to make room.
    static func apply(_ target: CGRect, read: () throws -> CGRect, resize: (CGRect) throws -> Void, position: (CGRect) throws -> Void) rethrows -> CGRect {
        var actual = try read()
        for _ in 0..<2 {
            var staging = actual
            if target.width > actual.width { staging.origin.x = min(actual.minX, target.minX) }
            if target.height > actual.height { staging.origin.y = min(actual.minY, target.minY) }
            if staging.origin != actual.origin { try position(staging) }
            try resize(target)
            try position(target)
            actual = try read()
            if close(actual, target) { break }
        }
        return actual
    }
}

/// One window, identified by its process and the hash of its Accessibility element.
struct WindowIdentity: Hashable, Sendable {
    var pid: pid_t
    var element: UInt
}

/// The last Left/Right Half application, so pressing the same command again steps through sizes.
struct CycleStep: Sendable {
    var window: WindowIdentity
    var layout: WindowLayout
    var index: Int
    var bounds: CGRect
}

/// Frames before Prism moved each window, for Restore Previous Layout. Bounded so it never grows without limit.
struct PreviousLayouts {
    static let capacity = 128

    private(set) var frames: [WindowIdentity: CGRect] = [:]
    private var order: [WindowIdentity] = []

    @discardableResult
    mutating func remember(_ window: WindowIdentity, _ bounds: CGRect) -> CGRect? {
        let previous = frames.updateValue(bounds, forKey: window)
        order.removeAll { $0 == window }
        order.append(window)
        while frames.count > Self.capacity, !order.isEmpty {
            frames[order.removeFirst()] = nil
        }
        return previous
    }

    /// Undoes `remember` after a failed layout so an earlier checkpoint survives.
    mutating func rollback(_ window: WindowIdentity, to previous: CGRect?) {
        frames[window] = nil
        order.removeAll { $0 == window }
        if let previous {
            frames[window] = previous
            order.append(window)
        }
    }

    func restoreBounds(_ window: WindowIdentity) -> CGRect? { frames[window] }

    mutating func completeRestore(_ window: WindowIdentity) {
        frames[window] = nil
        order.removeAll { $0 == window }
    }
}
