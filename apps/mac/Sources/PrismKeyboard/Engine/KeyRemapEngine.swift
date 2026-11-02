import CoreGraphics

/// One keyboard or mouse event as the engine sees it.
struct KeyInput: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case keyDown, keyUp, flagsChanged, mouse }

    var kind: Kind
    var keyCode: UInt16
    var flags: CGEventFlags
    var isRepeat = false
    /// Seconds, from any monotonic clock.
    var time: Double
}

/// A key event the engine wants posted.
struct KeyOutput: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case keyDown, keyUp, flagsChanged }

    var kind: Kind
    var keyCode: UInt16
    var flags: CGEventFlags
}

/// What to do with an incoming event: let it through (possibly with another key code or flags) or drop it,
/// then post `posts` in order.
struct KeyDecision: Equatable, Sendable {
    struct Passed: Equatable, Sendable {
        var keyCode: UInt16
        var flags: CGEventFlags
    }

    var current: Passed?
    var posts: [KeyOutput] = []

    static let drop = KeyDecision(current: nil)

    static func drop(posting posts: [KeyOutput]) -> KeyDecision {
        KeyDecision(current: nil, posts: posts)
    }
}

/// A key with exact modifiers, such as ⌘K.
struct KeyCombo: Hashable, Codable, Sendable {
    var keyCode: UInt16
    var modifiers: KeyModifiers
}

/// A key that types itself when tapped and acts as modifiers while held.
struct DualRole: Equatable, Sendable {
    /// The key a tap types. `nil` types nothing.
    var tap: UInt16?
    var hold: KeyModifiers
}

/// The rules compiled from `KeyboardConfig` for the event tap.
struct KeyEngineRules: Equatable, Sendable {
    var dualRoles: [UInt16: DualRole] = [:]
    var remaps: [KeyCombo: KeyCombo] = [:]
    var appRemaps: [String: [KeyCombo: KeyCombo]] = [:]
    /// Apps where tap-and-hold keys behave normally, such as games.
    var dualRoleExcludedApps: Set<String> = []
    /// Another key pressed this long after a tap-and-hold key counts as a shortcut straight away.
    var holdThreshold: Double = 0.2

    /// A tap-and-hold key released later than this, with nothing pressed in between, types nothing.
    static let aloneTimeout: Double = 1.0

    var isEmpty: Bool { dualRoles.isEmpty && remaps.isEmpty && appRemaps.isEmpty }
}

/// Turns hardware key events into remapped ones: tap-and-hold keys (Space types a space when tapped and acts as
/// ⌘ while held) and shortcut remaps, optionally per app. Pure state, so it can be tested without an event tap.
///
/// A tap-and-hold key is decided as late as possible so fast typing does not turn into shortcuts:
/// - Pressed alone and released within `aloneTimeout`: a tap.
/// - Another key pressed and released while it is still down ("permissive hold"): a hold.
/// - Released while another key is still down, as when typing quickly with overlapping keys: a tap, then that key.
/// - Another key pressed after `holdThreshold`, or a mouse button pressed: a hold.
/// Held with ⌘, ⌃, ⌥ or ⇧ already down (⌃Space for input sources), the key is left alone.
struct KeyRemapEngine: Sendable {
    var rules = KeyEngineRules() {
        didSet { if rules != oldValue { pendingReset = true } }
    }
    var frontmostApp: String?
    /// While a recorder in Prism's settings listens, shortcut remaps stay off so the real keys are recorded.
    var remapsPaused = false

    private struct Active: Sendable {
        var trigger: UInt16
        var role: DualRole
        var start: Double
        var held = false
        var buffered: [KeyInput] = []
    }

    private var active: Active?
    /// Keys whose press was remapped, so their repeats and release follow the same remap.
    private var remappedKeys: [UInt16: KeyCombo] = [:]
    private var pendingReset = false

    var isIdle: Bool { active == nil && remappedKeys.isEmpty }

    mutating func handle(_ input: KeyInput) -> KeyDecision {
        var resetPosts: [KeyOutput] = []
        if pendingReset {
            pendingReset = false
            resetPosts = reset(flags: input.flags)
        }
        var decision = decide(input)
        decision.posts = resetPosts + decision.posts
        return decision
    }

    /// Forgets every pressed key, releasing held modifiers. Used when the tap restarts or the rules change.
    mutating func reset(flags: CGEventFlags = []) -> [KeyOutput] {
        defer {
            active = nil
            remappedKeys = [:]
        }
        guard let active, active.held else { return [] }
        return Self.modifierChanges(active.role.hold, base: flags, pressing: false)
    }

    // MARK: Decisions

    private mutating func decide(_ input: KeyInput) -> KeyDecision {
        switch input.kind {
        case .mouse: return mouse(input)
        case .flagsChanged: return KeyDecision(current: .init(keyCode: input.keyCode, flags: input.flags.union(heldFlags)))
        case .keyDown, .keyUp: return key(input)
        }
    }

    private var heldFlags: CGEventFlags {
        guard let active, active.held else { return [] }
        return active.role.hold.flags
    }

    /// A click while a tap-and-hold key is down means the modifier (⌘-click).
    private mutating func mouse(_ input: KeyInput) -> KeyDecision {
        guard var active else { return KeyDecision(current: .init(keyCode: input.keyCode, flags: input.flags)) }
        var posts: [KeyOutput] = []
        if !active.held {
            posts = resolveHold(&active, base: input.flags)
            self.active = active
        }
        return KeyDecision(current: .init(keyCode: input.keyCode, flags: input.flags.union(active.role.hold.flags)), posts: posts)
    }

    private mutating func key(_ input: KeyInput) -> KeyDecision {
        if var active {
            if input.keyCode == active.trigger { return trigger(input, active: active) }
            if active.held { return pass(input, adding: active.role.hold.flags) }
            switch input.kind {
            case .keyDown:
                if input.isRepeat || input.time - active.start >= rules.holdThreshold {
                    var posts = resolveHold(&active, base: input.flags)
                    posts += remapOutputs(input, adding: active.role.hold.flags)
                    self.active = active
                    return .drop(posting: posts)
                }
                active.buffered.append(input)
                self.active = active
                return .drop
            default:
                guard active.buffered.contains(where: { $0.keyCode == input.keyCode }) else { return pass(input) }
                var posts = resolveHold(&active, base: input.flags)
                posts += remapOutputs(input, adding: active.role.hold.flags)
                self.active = active
                return .drop(posting: posts)
            }
        }
        if input.kind == .keyDown, !input.isRepeat, let role = rules.dualRoles[input.keyCode],
           KeyModifiers(flags: input.flags).isEmpty,
           frontmostApp.map({ !rules.dualRoleExcludedApps.contains($0) }) ?? true {
            active = Active(trigger: input.keyCode, role: role, start: input.time)
            return .drop
        }
        return pass(input)
    }

    /// The tap-and-hold key itself: its repeats are swallowed; its release decides tap or hold.
    private mutating func trigger(_ input: KeyInput, active: Active) -> KeyDecision {
        guard input.kind == .keyUp else { return .drop }
        self.active = nil
        if active.held {
            return .drop(posting: Self.modifierChanges(active.role.hold, base: input.flags, pressing: false))
        }
        let isTap = !active.buffered.isEmpty || input.time - active.start < KeyEngineRules.aloneTimeout
        var posts: [KeyOutput] = []
        if isTap, let tap = active.role.tap {
            for kind in [KeyInput.Kind.keyDown, .keyUp] {
                posts += remapOutputs(KeyInput(kind: kind, keyCode: tap, flags: input.flags, time: input.time))
            }
        }
        for buffered in active.buffered { posts += remapOutputs(buffered) }
        return .drop(posting: posts)
    }

    /// Presses the hold modifiers, then replays the keys typed while undecided with them.
    private mutating func resolveHold(_ active: inout Active, base: CGEventFlags) -> [KeyOutput] {
        active.held = true
        var posts = Self.modifierChanges(active.role.hold, base: base, pressing: true)
        for buffered in active.buffered { posts += remapOutputs(buffered, adding: active.role.hold.flags) }
        active.buffered = []
        return posts
    }

    // MARK: Remaps

    private mutating func pass(_ input: KeyInput, adding extra: CGEventFlags = []) -> KeyDecision {
        let (keyCode, flags) = remap(input, flags: input.flags.union(extra))
        return KeyDecision(current: .init(keyCode: keyCode, flags: flags))
    }

    private mutating func remapOutputs(_ input: KeyInput, adding extra: CGEventFlags = []) -> [KeyOutput] {
        let (keyCode, flags) = remap(input, flags: input.flags.union(extra))
        return [KeyOutput(kind: input.kind == .keyUp ? .keyUp : .keyDown, keyCode: keyCode, flags: flags)]
    }

    private mutating func remap(_ input: KeyInput, flags: CGEventFlags) -> (UInt16, CGEventFlags) {
        switch input.kind {
        case .keyDown:
            if let target = remappedKeys[input.keyCode] { return Self.apply(target, to: flags) }
            guard !remapsPaused, let target = target(for: KeyCombo(keyCode: input.keyCode, modifiers: KeyModifiers(flags: flags)))
            else { return (input.keyCode, flags) }
            remappedKeys[input.keyCode] = target
            return Self.apply(target, to: flags)
        case .keyUp:
            guard let target = remappedKeys.removeValue(forKey: input.keyCode) else { return (input.keyCode, flags) }
            return Self.apply(target, to: flags)
        default:
            return (input.keyCode, flags)
        }
    }

    private func target(for combo: KeyCombo) -> KeyCombo? {
        if let frontmostApp, let target = rules.appRemaps[frontmostApp]?[combo] { return target }
        return rules.remaps[combo]
    }

    private static func apply(_ target: KeyCombo, to flags: CGEventFlags) -> (UInt16, CGEventFlags) {
        (target.keyCode, flags.subtracting(KeyModifiers.allFlags).union(target.modifiers.flags))
    }

    // MARK: Modifier events

    /// `flagsChanged` events that press or release each modifier in turn, as a keyboard would.
    static func modifierChanges(_ modifiers: KeyModifiers, base: CGEventFlags, pressing: Bool) -> [KeyOutput] {
        var flags = pressing ? base : base.union(modifiers.flags)
        let order = pressing ? KeyModifiers.ordered : KeyModifiers.ordered.reversed()
        return order.filter { modifiers.contains($0.modifier) }.map { entry in
            if pressing {
                flags.formUnion(entry.modifier.flags)
            } else {
                flags.subtract(entry.modifier.flags)
                flags.formUnion(base.intersection(entry.modifier.flags))
            }
            return KeyOutput(kind: .flagsChanged, keyCode: entry.keyCode, flags: flags)
        }
    }
}

/// ⌃⌥⇧⌘, stored as small bits so settings files stay readable.
struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let control = KeyModifiers(rawValue: 1)
    static let option = KeyModifiers(rawValue: 2)
    static let shift = KeyModifiers(rawValue: 4)
    static let command = KeyModifiers(rawValue: 8)
    /// ⌃⌥⇧⌘, a modifier combination no app uses, for global shortcuts of your own.
    static let hyper: KeyModifiers = [.control, .option, .shift, .command]
    /// ⌃⌥⇧.
    static let meh: KeyModifiers = [.control, .option, .shift]

    /// Each modifier with its left-hand key code, in the order a keyboard presses them.
    static let ordered: [(modifier: KeyModifiers, keyCode: UInt16)] = [
        (.control, 0x3B), (.option, 0x3A), (.shift, 0x38), (.command, 0x37),
    ]

    /// Device-dependent bits (`NX_DEVICEL…KEYMASK`) that some apps read to tell left from right.
    private static let leftDeviceBits: [KeyModifiers: UInt64] = [.control: 0x1, .shift: 0x2, .command: 0x8, .option: 0x20]
    private static let allDeviceBits: UInt64 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000

    static let allFlags = CGEventFlags(rawValue: CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand]).rawValue | allDeviceBits)

    init(flags: CGEventFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        self = modifiers
    }

    var flags: CGEventFlags {
        var flags = CGEventFlags()
        var device: UInt64 = 0
        for (modifier, mask) in [(KeyModifiers.control, CGEventFlags.maskControl), (.option, .maskAlternate), (.shift, .maskShift), (.command, .maskCommand)]
            where contains(modifier) {
            flags.insert(mask)
            device |= Self.leftDeviceBits[modifier] ?? 0
        }
        return CGEventFlags(rawValue: flags.rawValue | device)
    }

    var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}
