import CoreGraphics
import Foundation
import Testing
@testable import PrismKeyboard

private let space: UInt16 = 0x31
private let keyA: UInt16 = 0x00
private let keyB: UInt16 = 0x0B
private let keyC: UInt16 = 0x08
private let keyK: UInt16 = 0x28
private let escape: UInt16 = 0x35
private let f18: UInt16 = 0x4F
private let command = KeyModifiers.command.flags

private func down(_ key: UInt16, _ time: Double, flags: CGEventFlags = [], isRepeat: Bool = false) -> KeyInput {
    KeyInput(kind: .keyDown, keyCode: key, flags: flags, isRepeat: isRepeat, time: time)
}

private func up(_ key: UInt16, _ time: Double, flags: CGEventFlags = []) -> KeyInput {
    KeyInput(kind: .keyUp, keyCode: key, flags: flags, time: time)
}

private func spaceAsCommand() -> KeyRemapEngine {
    var engine = KeyRemapEngine()
    engine.rules.dualRoles[space] = DualRole(tap: space, hold: .command)
    _ = engine.handle(KeyInput(kind: .flagsChanged, keyCode: 0, flags: [], time: 0))
    return engine
}

/// The keys an engine emits for a sequence: passed events and posted ones, in order.
private func run(_ engine: inout KeyRemapEngine, _ inputs: [KeyInput]) -> [KeyOutput] {
    var outputs: [KeyOutput] = []
    for input in inputs {
        let decision = engine.handle(input)
        if let current = decision.current {
            let kind: KeyOutput.Kind = switch input.kind {
            case .keyDown: .keyDown
            case .keyUp: .keyUp
            default: .flagsChanged
            }
            outputs.append(KeyOutput(kind: kind, keyCode: current.keyCode, flags: current.flags))
        }
        outputs += decision.posts
    }
    return outputs
}

private func keys(_ outputs: [KeyOutput]) -> [String] {
    outputs.map { output in
        switch output.kind {
        case .flagsChanged: KeyModifiers(flags: output.flags).contains(.command) ? "⌘↓" : "⌘↑"
        case .keyDown: "\(KeyModifiers(flags: output.flags).symbols)\(output.keyCode)↓"
        case .keyUp: "\(KeyModifiers(flags: output.flags).symbols)\(output.keyCode)↑"
        }
    }
}

@Suite struct DualRoleTests {
    @Test func tappingTypesSpace() {
        var engine = spaceAsCommand()
        #expect(keys(run(&engine, [down(space, 0), up(space, 0.1)])) == ["49↓", "49↑"])
    }

    @Test func holdingWithAKeyPressesCommand() {
        var engine = spaceAsCommand()
        let outputs = run(&engine, [down(space, 0), down(keyC, 0.05), up(keyC, 0.1), up(space, 0.15)])
        #expect(keys(outputs) == ["⌘↓", "⌘8↓", "⌘8↑", "⌘↑"])
    }

    @Test func overlappingTypingStaysText() {
        // Space released before the next letter: fast typing, not ⌘B.
        var engine = spaceAsCommand()
        let outputs = run(&engine, [down(space, 0), down(keyB, 0.04), up(space, 0.07), up(keyB, 0.1)])
        #expect(keys(outputs) == ["49↓", "49↑", "11↓", "11↑"])
    }

    @Test func keyAfterThresholdIsAShortcutAtOnce() {
        var engine = spaceAsCommand()
        let outputs = run(&engine, [down(space, 0), down(keyK, 0.3)])
        #expect(keys(outputs) == ["⌘↓", "⌘40↓"])
        #expect(keys(run(&engine, [up(keyK, 0.35), up(space, 0.4)])) == ["⌘40↑", "⌘↑"])
    }

    @Test func heldKeysKeepCommandUntilReleased() {
        var engine = spaceAsCommand()
        _ = run(&engine, [down(space, 0), down(keyK, 0.3), up(keyK, 0.32)])
        let outputs = run(&engine, [down(keyA, 0.4), up(keyA, 0.45), up(space, 0.5), down(keyA, 0.6)])
        #expect(keys(outputs) == ["⌘0↓", "⌘0↑", "⌘↑", "0↓"])
    }

    @Test func longHoldAloneTypesNothing() {
        var engine = spaceAsCommand()
        #expect(run(&engine, [down(space, 0), up(space, 1.5)]).isEmpty)
    }

    @Test func repeatsOfTheHeldKeyAreSwallowed() {
        var engine = spaceAsCommand()
        let outputs = run(&engine, [down(space, 0), down(space, 0.5, isRepeat: true), down(space, 0.55, isRepeat: true), up(space, 0.6)])
        #expect(keys(outputs) == ["49↓", "49↑"])
    }

    @Test func withModifiersSpaceIsLeftAlone() {
        // ⌃Space switches input sources.
        var engine = spaceAsCommand()
        let control = KeyModifiers.control.flags
        let outputs = run(&engine, [down(space, 0, flags: control), up(space, 0.05, flags: control)])
        #expect(outputs == [KeyOutput(kind: .keyDown, keyCode: space, flags: control), KeyOutput(kind: .keyUp, keyCode: space, flags: control)])
    }

    @Test func clickWhileHeldIsCommandClick() {
        var engine = spaceAsCommand()
        _ = engine.handle(down(space, 0))
        let decision = engine.handle(KeyInput(kind: .mouse, keyCode: 0, flags: [], time: 0.05))
        #expect(decision.current?.flags.contains(.maskCommand) == true)
        #expect(keys(decision.posts) == ["⌘↓"])
        #expect(keys(run(&engine, [up(space, 0.2)])) == ["⌘↑"])
    }

    @Test func excludedAppTypesNormally() {
        var engine = spaceAsCommand()
        engine.rules.dualRoleExcludedApps = ["com.example.game"]
        engine.frontmostApp = "com.example.game"
        #expect(keys(run(&engine, [down(space, 0), down(keyC, 0.05)])) == ["49↓", "8↓"])
    }

    @Test func capsLockTapsEscapeAndHoldsHyper() {
        var engine = KeyRemapEngine()
        engine.rules.dualRoles[f18] = DualRole(tap: escape, hold: .hyper)
        #expect(keys(run(&engine, [down(f18, 0), up(f18, 0.1)])) == ["53↓", "53↑"])
        let outputs = run(&engine, [down(f18, 1), down(keyK, 1.05), up(keyK, 1.1), up(f18, 1.2)])
        #expect(outputs.filter { $0.kind == .flagsChanged }.count == 8)
        #expect(outputs.first { $0.kind == .keyDown }.map { KeyModifiers(flags: $0.flags) } == .hyper)
        #expect(outputs.last.map { KeyModifiers(flags: $0.flags) } == [])
    }

    @Test func changingRulesReleasesHeldModifiers() {
        var engine = spaceAsCommand()
        _ = run(&engine, [down(space, 0), down(keyK, 0.3)])
        engine.rules = KeyEngineRules()
        let decision = engine.handle(down(keyA, 0.4))
        #expect(keys(decision.posts) == ["⌘↑"])
        #expect(decision.current == .init(keyCode: keyA, flags: []))
    }
}

@Suite struct ShortcutRemapTests {
    private func engine(_ from: KeyCombo, _ to: KeyCombo, app: String? = nil) -> KeyRemapEngine {
        var engine = KeyRemapEngine()
        if let app { engine.rules.appRemaps[app] = [from: to] } else { engine.rules.remaps[from] = to }
        return engine
    }

    @Test func remapsAShortcut() {
        var engine = engine(KeyCombo(keyCode: keyK, modifiers: .command), KeyCombo(keyCode: escape, modifiers: []))
        let outputs = run(&engine, [down(keyK, 0, flags: command), up(keyK, 0.1, flags: command)])
        #expect(outputs == [KeyOutput(kind: .keyDown, keyCode: escape, flags: []), KeyOutput(kind: .keyUp, keyCode: escape, flags: [])])
    }

    @Test func releaseFollowsThePressAfterModifiersLetGo() {
        var engine = engine(KeyCombo(keyCode: keyK, modifiers: .command), KeyCombo(keyCode: keyA, modifiers: .option))
        let outputs = run(&engine, [down(keyK, 0, flags: command), up(keyK, 0.1)])
        #expect(outputs.map(\.keyCode) == [keyA, keyA])
        #expect(outputs.allSatisfy { KeyModifiers(flags: $0.flags) == .option })
    }

    @Test func otherModifiersDoNotMatch() {
        var engine = engine(KeyCombo(keyCode: keyK, modifiers: .command), KeyCombo(keyCode: escape, modifiers: []))
        let flags = KeyModifiers([.command, .shift]).flags
        #expect(run(&engine, [down(keyK, 0, flags: flags)]).map(\.keyCode) == [keyK])
    }

    @Test func appRemapsApplyOnlyInThatApp() {
        var engine = engine(KeyCombo(keyCode: keyK, modifiers: .command), KeyCombo(keyCode: escape, modifiers: []), app: "com.example.editor")
        engine.frontmostApp = "com.example.browser"
        #expect(run(&engine, [down(keyK, 0, flags: command), up(keyK, 0.05, flags: command)]).map(\.keyCode) == [keyK, keyK])
        engine.frontmostApp = "com.example.editor"
        #expect(run(&engine, [down(keyK, 1, flags: command), up(keyK, 1.05, flags: command)]).map(\.keyCode) == [escape, escape])
    }

    @Test func heldSpaceFeedsRemaps() {
        var engine = engine(KeyCombo(keyCode: keyK, modifiers: .command), KeyCombo(keyCode: escape, modifiers: []))
        engine.rules.dualRoles[space] = DualRole(tap: space, hold: .command)
        let outputs = run(&engine, [down(space, 0), down(keyK, 0.05), up(keyK, 0.1), up(space, 0.2)])
        #expect(outputs.filter { $0.kind != .flagsChanged }.map(\.keyCode) == [escape, escape])
    }

    @Test func pausedRemapsPassKeysThrough() {
        var engine = engine(KeyCombo(keyCode: keyK, modifiers: .command), KeyCombo(keyCode: escape, modifiers: []))
        engine.remapsPaused = true
        #expect(run(&engine, [down(keyK, 0, flags: command)]).map(\.keyCode) == [keyK])
    }
}

@Suite struct KeyboardConfigTests {
    @Test func offConfigHasNoRules() {
        var config = KeyboardConfig()
        config.dualRoles = [.spaceCommand]
        #expect(config.engineRules.isEmpty)
        config.enabled = true
        #expect(config.engineRules.dualRoles[space] == DualRole(tap: space, hold: .command))
        #expect(!config.needsCapsLockMapping)
    }

    @Test func capsLockRuleNeedsTheMapping() {
        var config = KeyboardConfig()
        config.enabled = true
        config.dualRoles = [.capsLockHyper]
        #expect(config.needsCapsLockMapping)
        #expect(config.engineRules.dualRoles[f18] == DualRole(tap: escape, hold: .hyper))
    }

    @Test func incompleteRemapsAreSkipped() {
        var config = KeyboardConfig()
        config.enabled = true
        config.remaps = [ShortcutRemap(from: KeyCombo(keyCode: keyK, modifiers: .command))]
        #expect(config.engineRules.isEmpty)
    }

    @Test func decodesOlderFilesWithDefaults() throws {
        let config = try JSONDecoder().decode(KeyboardConfig.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(config.enabled && config.holdThreshold == 200 && config.dualRoles.isEmpty)
    }

    @Test func roundTrips() throws {
        var config = KeyboardConfig()
        config.dualRoles = [.spaceCommand]
        config.remaps = [ShortcutRemap(from: KeyCombo(keyCode: keyK, modifiers: .command), to: KeyCombo(keyCode: escape, modifiers: []),
                                       app: AppReference(bundleID: "com.example", name: "Example"))]
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(KeyboardConfig.self, from: data) == config)
    }
}

@Suite struct CapsLockMappingTests {
    @Test func parsesHidutilOutput() {
        let output = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771183;
                HIDKeyboardModifierMappingSrc = 30064771182;
            }
        )
        """
        #expect(CapsLockMapping.parse(output) == [.init(source: 30_064_771_182, destination: 30_064_771_183)])
        #expect(CapsLockMapping.parse("(\n)").isEmpty)
    }

    @Test func mergeKeepsOtherMappings() {
        let other = CapsLockMapping.Entry(source: 1, destination: 2)
        #expect(CapsLockMapping.merged([other], wanted: true) == [other, CapsLockMapping.entry])
        #expect(CapsLockMapping.merged([other, CapsLockMapping.entry], wanted: false) == [other])
        #expect(CapsLockMapping.merged([CapsLockMapping.Entry(source: CapsLockMapping.capsLock, destination: 9)], wanted: true) == [CapsLockMapping.entry])
    }

    @Test func writesJSON() {
        #expect(CapsLockMapping.json([]) == #"{"UserKeyMapping":[]}"#)
    }
}
