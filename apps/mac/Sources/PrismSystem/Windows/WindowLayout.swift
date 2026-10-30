import Foundation

/// Every window command. Raw values are the Tauri action names; the command ID is `window:<rawValue>`.
enum WindowLayout: String, CaseIterable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case topLeftSixth = "top-left-sixth"
    case topCenterSixth = "top-center-sixth"
    case topRightSixth = "top-right-sixth"
    case bottomLeftSixth = "bottom-left-sixth"
    case bottomCenterSixth = "bottom-center-sixth"
    case bottomRightSixth = "bottom-right-sixth"
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case leftTwoThirds = "left-two-thirds"
    case centerTwoThirds = "center-two-thirds"
    case rightTwoThirds = "right-two-thirds"
    case maximize
    case almostMaximize = "almost-maximize"
    case center
    case maximizeWidth = "maximize-width"
    case maximizeHeight = "maximize-height"
    case reasonableSize = "reasonable-size"
    case firstFourth = "first-fourth"
    case secondFourth = "second-fourth"
    case thirdFourth = "third-fourth"
    case lastFourth = "last-fourth"
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case moveUp = "move-up"
    case moveDown = "move-down"
    case nextDisplay = "next-display"
    case previousDisplay = "previous-display"
    case restorePreviousLayout = "restore-previous-layout"

    static let commandPrefix = "window:"

    var commandID: String { Self.commandPrefix + rawValue }

    /// Accepts the same spellings as the Tauri parser, including `window:` command IDs.
    init?(parsing raw: String) {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix(Self.commandPrefix) { name.removeFirst(Self.commandPrefix.count) }
        switch name {
        case "left_half", "left": self = .leftHalf
        case "right_half", "right": self = .rightHalf
        case "maximise": self = .maximize
        case "almost-maximise": self = .almostMaximize
        case "centre": self = .center
        case "restore_previous_layout", "restore": self = .restorePreviousLayout
        default:
            guard let layout = WindowLayout(rawValue: name) else { return nil }
            self = layout
        }
    }

    var isDisplayMove: Bool { self == .nextDisplay || self == .previousDisplay }
    var cycles: Bool { self == .leftHalf || self == .rightHalf }

    /// Layouts that tile against neighbours and therefore receive half of the window gap on inner edges.
    var receivesGap: Bool {
        switch self {
        case .center, .maximize, .restorePreviousLayout, .maximizeWidth, .maximizeHeight, .reasonableSize,
             .moveLeft, .moveRight, .moveUp, .moveDown, .nextDisplay, .previousDisplay:
            false
        default:
            true
        }
    }

    enum Group: CaseIterable {
        case split, position, display
    }

    var group: Group {
        if isDisplayMove { return .display }
        let name = rawValue
        return ["half", "third", "quarter", "sixth", "fourth"].contains(where: name.contains) ? .split : .position
    }

    /// English source title. Localized through the module bundle.
    var englishTitle: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeftQuarter: "Top Left Quarter"
        case .topRightQuarter: "Top Right Quarter"
        case .bottomLeftQuarter: "Bottom Left Quarter"
        case .bottomRightQuarter: "Bottom Right Quarter"
        case .topLeftSixth: "Top Left Sixth"
        case .topCenterSixth: "Top Center Sixth"
        case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"
        case .bottomCenterSixth: "Bottom Center Sixth"
        case .bottomRightSixth: "Bottom Right Sixth"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .center: "Center"
        case .maximizeWidth: "Maximize Width"
        case .maximizeHeight: "Maximize Height"
        case .reasonableSize: "Reasonable Size"
        case .firstFourth: "First Fourth"
        case .secondFourth: "Second Fourth"
        case .thirdFourth: "Third Fourth"
        case .lastFourth: "Last Fourth"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .restorePreviousLayout: "Restore Previous Layout"
        }
    }

    var title: String { SystemStrings.localized(englishTitle) }

    /// Search words from the Tauri catalog. The palette also matches the English and Korean titles.
    var keywords: [String] {
        let specific: [String] = switch self {
        case .leftHalf: ["left", "half"]
        case .rightHalf: ["right", "half"]
        case .topHalf: ["top", "half"]
        case .bottomHalf: ["bottom", "half"]
        case .topLeftQuarter: ["top", "left", "quarter"]
        case .topRightQuarter: ["top", "right", "quarter"]
        case .bottomLeftQuarter: ["bottom", "left", "quarter"]
        case .bottomRightQuarter: ["bottom", "right", "quarter"]
        case .topLeftSixth: ["top", "left", "sixth"]
        case .topCenterSixth: ["top", "center", "sixth"]
        case .topRightSixth: ["top", "right", "sixth"]
        case .bottomLeftSixth: ["bottom", "left", "sixth"]
        case .bottomCenterSixth: ["bottom", "center", "sixth"]
        case .bottomRightSixth: ["bottom", "right", "sixth"]
        case .firstThird: ["left", "first", "third"]
        case .centerThird: ["center", "middle", "third"]
        case .lastThird: ["right", "last", "third"]
        case .leftTwoThirds: ["left", "two", "thirds"]
        case .centerTwoThirds: ["center", "two", "thirds"]
        case .rightTwoThirds: ["right", "two", "thirds"]
        case .maximize: ["maximize", "fill", "screen"]
        case .almostMaximize: ["almost", "maximize", "margin"]
        case .center: ["center", "position"]
        case .maximizeWidth: ["maximize", "width"]
        case .maximizeHeight: ["maximize", "height"]
        case .reasonableSize: ["reasonable", "size"]
        case .firstFourth: ["first", "fourth"]
        case .secondFourth: ["second", "fourth"]
        case .thirdFourth: ["third", "fourth"]
        case .lastFourth: ["last", "fourth"]
        case .moveLeft: ["move", "left"]
        case .moveRight: ["move", "right"]
        case .moveUp: ["move", "up"]
        case .moveDown: ["move", "down"]
        case .nextDisplay: ["next", "display"]
        case .previousDisplay: ["previous", "display"]
        case .restorePreviousLayout: ["restore", "previous", "undo"]
        }
        return ["window", "move", "resize", "layout"] + specific
    }
}
