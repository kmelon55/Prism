import Carbon.HIToolbox
import Foundation

/// The saved keyboard settings, `keyboard-remapping-v1.json`. Everything is off until the user turns it on.
struct KeyboardConfig: Codable, Equatable, Sendable {
    static let fileName = "keyboard-remapping-v1.json"
    static let holdThresholdRange = 120...400

    var enabled = false
    /// Milliseconds after which a key pressed with a tap-and-hold key counts as a shortcut.
    var holdThreshold = 200
    var dualRoles: [DualRoleRule] = []
    var remaps: [ShortcutRemap] = []
    /// Apps where tap-and-hold keys behave normally, such as games.
    var excludedApps: [AppReference] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        holdThreshold = try container.decodeIfPresent(Int.self, forKey: .holdThreshold) ?? 200
        dualRoles = try container.decodeIfPresent([DualRoleRule].self, forKey: .dualRoles) ?? []
        remaps = try container.decodeIfPresent([ShortcutRemap].self, forKey: .remaps) ?? []
        excludedApps = try container.decodeIfPresent([AppReference].self, forKey: .excludedApps) ?? []
    }

    /// Whether Caps Lock must be turned into F18 so the event tap can see its presses and releases.
    var needsCapsLockMapping: Bool {
        enabled && (dualRoles.contains { $0.isEnabled && $0.trigger == .capsLock }
            || remaps.contains { $0.isEnabled && $0.from?.keyCode == TriggerKey.capsLock.keyCode })
    }

    /// The enabled rules, as the event tap uses them. A trigger used twice keeps its first rule.
    var engineRules: KeyEngineRules {
        var rules = KeyEngineRules()
        rules.holdThreshold = Double(holdThreshold.clamped(to: Self.holdThresholdRange)) / 1000
        guard enabled else { return rules }
        for rule in dualRoles where rule.isEnabled && rules.dualRoles[rule.trigger.keyCode] == nil {
            rules.dualRoles[rule.trigger.keyCode] = DualRole(tap: rule.tap.keyCode(trigger: rule.trigger), hold: rule.hold.modifiers)
        }
        for remap in remaps where remap.isEnabled {
            guard let from = remap.from, let to = remap.to, from != to else { continue }
            if let app = remap.app {
                if rules.appRemaps[app.bundleID, default: [:]][from] == nil { rules.appRemaps[app.bundleID, default: [:]][from] = to }
            } else if rules.remaps[from] == nil {
                rules.remaps[from] = to
            }
        }
        rules.dualRoleExcludedApps = Set(excludedApps.map(\.bundleID))
        return rules
    }
}

/// A key that types when tapped and acts as modifiers while held.
struct DualRoleRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var trigger: TriggerKey
    var tap: TapOutput
    var hold: HoldModifiers
    var isEnabled = true

    /// Space types a space when tapped and is ⌘ while held.
    static var spaceCommand: DualRoleRule { DualRoleRule(trigger: .space, tap: .same, hold: .command) }
    /// Caps Lock is Escape when tapped and ⌃⌥⇧⌘ while held.
    static var capsLockHyper: DualRoleRule { DualRoleRule(trigger: .capsLock, tap: .escape, hold: .hyper) }
}

/// Keys that can be tapped and held. Caps Lock reaches Prism as F18 (see `CapsLockMapping`).
enum TriggerKey: String, Codable, CaseIterable, Sendable {
    case space, capsLock, `return`, tab, escape, semicolon, quote

    var keyCode: UInt16 {
        switch self {
        case .space: UInt16(kVK_Space)
        case .capsLock: UInt16(kVK_F18)
        case .return: UInt16(kVK_Return)
        case .tab: UInt16(kVK_Tab)
        case .escape: UInt16(kVK_Escape)
        case .semicolon: UInt16(kVK_ANSI_Semicolon)
        case .quote: UInt16(kVK_ANSI_Quote)
        }
    }

    /// Caps Lock cannot be typed back; its tap needs another key.
    var canTypeItself: Bool { self != .capsLock }
}

/// What a tap types.
enum TapOutput: String, Codable, CaseIterable, Sendable {
    case same, escape, `return`, tab, space, delete, nothing

    func keyCode(trigger: TriggerKey) -> UInt16? {
        switch self {
        case .same: trigger.canTypeItself ? trigger.keyCode : nil
        case .escape: UInt16(kVK_Escape)
        case .return: UInt16(kVK_Return)
        case .tab: UInt16(kVK_Tab)
        case .space: UInt16(kVK_Space)
        case .delete: UInt16(kVK_Delete)
        case .nothing: nil
        }
    }
}

/// The modifiers a held key becomes.
enum HoldModifiers: String, Codable, CaseIterable, Sendable {
    case command, control, option, shift, hyper, meh

    var modifiers: KeyModifiers {
        switch self {
        case .command: .command
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .hyper: .hyper
        case .meh: .meh
        }
    }
}

/// One shortcut replaced by another, everywhere or in one app.
struct ShortcutRemap: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var from: KeyCombo?
    var to: KeyCombo?
    /// `nil` applies everywhere.
    var app: AppReference?
    var isEnabled = true
}

struct AppReference: Codable, Hashable, Sendable {
    var bundleID: String
    var name: String
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
