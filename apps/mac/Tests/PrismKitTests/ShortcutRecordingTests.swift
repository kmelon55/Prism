import AppKit
import Carbon.HIToolbox
import Testing
@testable import PrismKit

@MainActor
struct ShortcutRecordingTests {
    private func event(_ code: Int, modifiers: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: UInt16(code)))
    }

    @Test func commandSpaceResumesRegistrationBeforeCommitting() throws {
        var paused = true
        var stored = Shortcut.launcherDefault
        var commits = 0
        let result = ShortcutRecording.capture(try event(kVK_Space, modifiers: .command, characters: " "),
                                               stop: { paused = false }) { shortcut in
            #expect(!paused)
            if !paused, let shortcut { stored = shortcut }
            commits += 1
        }
        #expect(result == nil)
        #expect(commits == 1)
        #expect(stored.accelerator == "super+Space")
    }

    @Test func recordsPhysicalKeysWithKoreanInput() throws {
        var recorded: Shortcut?
        _ = ShortcutRecording.capture(try event(kVK_ANSI_K, modifiers: [.command, .shift], characters: "ㅏ"),
                                      stop: {}) { recorded = $0 }
        #expect(recorded?.accelerator == "shift+super+KeyK")
    }

    @Test func escapeCancelsWithoutChangingTheBinding() throws {
        var stopped = false
        var committed = false
        _ = ShortcutRecording.capture(try event(kVK_Escape), stop: { stopped = true }) { _ in committed = true }
        #expect(stopped)
        #expect(!committed)
    }

    @Test func deleteResumesRegistrationBeforeClearing() throws {
        var paused = true
        var cleared = false
        _ = ShortcutRecording.capture(try event(kVK_Delete), stop: { paused = false }) { shortcut in
            #expect(!paused)
            cleared = shortcut == nil
        }
        #expect(cleared)
    }

    @Test func functionKeysDoNotRequireModifiers() throws {
        var recorded: Shortcut?
        _ = ShortcutRecording.capture(try event(kVK_F6), stop: {}) { recorded = $0 }
        #expect(recorded?.accelerator == "F6")
    }
}
