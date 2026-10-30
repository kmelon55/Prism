import AppKit
import Testing
@testable import PrismDictation

/// A mutable value shared with injected environment closures.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Text delivery with injected environments and an isolated pasteboard. The user's clipboard and other apps are
/// never touched.
@MainActor
struct DeliveryTests {
    @Test func clipboardWritesReadBackAndMarkHistoryExclusion() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(TextInjector.copy("복구할 받아쓰기 👋", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "복구할 받아쓰기 👋")
        #expect(pasteboard.types?.contains(TextInjector.transientType) != true)
        #expect(TextInjector.copy("비공개 받아쓰기 👋", to: pasteboard, saveToHistory: false))
        #expect(pasteboard.string(forType: .string) == "비공개 받아쓰기 👋")
        #expect(pasteboard.types?.contains(TextInjector.transientType) == true)
        #expect(TextInjector.copy("기록 다시 켜기", to: pasteboard))
        #expect(pasteboard.types?.contains(TextInjector.transientType) != true)
    }

    @Test func capturesTheRightTarget() {
        let app = NSRunningApplication.current
        let prismPID = ProcessInfo.processInfo.processIdentifier
        var focusedPIDs: [pid_t] = []
        let foreground = Box<pid_t?>(prismPID)
        let environment = TextInjector.Environment(running: { _ in true }, permission: { true }, frontmostPID: { foreground.value },
                                                   focused: { pid in focusedPIDs.append(pid); return nil }, application: { _ in app })
        let prismTarget = TextInjector.captureTarget(fallbackPID: prismPID, environment: environment)
        #expect(prismTarget?.processIdentifier == prismPID && focusedPIDs == [prismPID], "Dictation started in Prism targets Prism")
        #expect(TextInjector.captureTarget(fallbackPID: 0, environment: environment) == nil,
                "A launcher command with no previous app must not target Prism")
        #expect(TextInjector.captureTarget(fallbackPID: prismPID + 1, environment: environment)?.processIdentifier == prismPID + 1)
        foreground.value = prismPID + 1
        #expect(TextInjector.captureTarget(fallbackPID: prismPID, environment: environment)?.processIdentifier == prismPID + 1,
                "A shortcut in another app targets that app")
        #expect(TextInjector.captureTarget(fallbackPID: prismPID, environment: .init(frontmostPID: { nil })) == nil)
        let noPermission = TextInjector.Environment(running: { _ in true }, permission: { false }, frontmostPID: { prismPID },
                                                    focused: { _ in Issue.record("AX queried without permission"); return nil },
                                                    application: { _ in app })
        #expect(TextInjector.captureTarget(fallbackPID: prismPID, environment: noPermission)?.processIdentifier == prismPID)
    }

    @Test func pastesWithoutAXAndGuardsFocusAndClipboardRaces() async {
        let app = NSRunningApplication.current
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = TextInsertionTarget(processIdentifier: pid, focusedElement: nil, application: app)
        var posted: [String] = []
        let foreground = Box<pid_t?>(pid)
        let revision = Box(1)
        let environment = TextInjector.Environment(running: { _ in true }, permission: { true }, frontmostPID: { foreground.value }, activate: { _ in },
                                                   focused: { _ in nil }, paste: { _ in posted.append("paste"); return true },
                                                   enter: { _ in posted.append("enter"); return true }, revision: { revision.value })
        let opaque = await TextInjector.deliver("long transcript", paste: true, pressEnterAfterPaste: true, target: target,
                                                copyText: { _ in true }, environment: environment)
        #expect(opaque == .pasteSent && posted == ["paste", "enter"], "Missing AX focus must not block keyboard delivery")
        posted = []
        foreground.value = -1
        let lostFocus = await TextInjector.deliver("long transcript", paste: true, pressEnterAfterPaste: true, target: target,
                                                   copyText: { _ in true }, environment: environment)
        #expect(lostFocus == .copied && posted.isEmpty, "Never paste into a different foreground app")
        foreground.value = pid
        // Every read sees a newer clipboard, as if another app copied while Prism was about to paste.
        var racing = environment
        racing.revision = {
            revision.value += 1
            return revision.value
        }
        let raced = await TextInjector.deliver("long transcript", paste: true, pressEnterAfterPaste: true, target: target,
                                               copyText: { _ in true }, environment: racing)
        #expect(raced == .copied && posted.isEmpty, "Never paste a clipboard replaced during delivery")
        #expect(TextInjector.pasteResult(observable: true, confirmed: false) == .unverified)
        #expect(TextInjector.pasteResult(observable: true, confirmed: true) == .pasted)
        #expect(!TextDeliveryResult.pasteSent.enteredInTargetApp, "Posted events are not proof of insertion")
    }

    @Test func copiesWithoutATargetAndHonorsCancellation() async {
        var writes: [String] = []
        let noTarget = await TextInjector.deliver("recoverable transcript", paste: true, pressEnterAfterPaste: false, target: nil,
                                                  copyText: { writes.append($0); return true }, environment: .init(permission: { true }))
        #expect(writes == ["recoverable transcript"] && noTarget == .copied)
        let denied = await TextInjector.deliver("x", paste: true, pressEnterAfterPaste: false, target: nil,
                                                copyText: { _ in true }, environment: .init(permission: { false }))
        #expect(denied == .permissionRequired)
        let failed = await TextInjector.deliver("x", paste: true, pressEnterAfterPaste: true, target: nil, copyText: { _ in false })
        #expect(failed == .copyFailed)
        let copyOnly = await TextInjector.deliver("copy only", paste: false, pressEnterAfterPaste: false, target: nil,
                                                  copyText: { writes.append($0); return true })
        #expect(copyOnly == .copied && writes.last == "copy only")
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await TextInjector.deliver("cancelled", paste: false, pressEnterAfterPaste: false, target: nil,
                                              copyText: { writes.append($0); return true })
        }
        _ = await cancelled.value
        #expect(!writes.contains("cancelled"))
    }

    @Test func insertionExpectationUsesUTF16Ranges() {
        let expectation = TextInsertionExpectation(value: "안녕 👋 world", range: CFRange(location: 6, length: 5), text: "Prism")
        #expect(expectation?.confirms("안녕 👋 Prism") == true)
        #expect(expectation?.confirms("안녕 👋 world") == false && expectation?.confirms(nil) == false)
        #expect(expectation?.confirms("Prism") == false)
        #expect(TextInsertionExpectation(value: "same", range: CFRange(location: 0, length: 4), text: "same")?.confirms("same") == false)
        #expect(TextInsertionExpectation(value: "a", range: CFRange(location: 2, length: 0), text: "b") == nil)
        #expect(TextInsertionExpectation(value: "a", range: CFRange(location: 0, length: Int.max), text: "b") == nil)
        #expect(!TextDeliveryResult.unverified.enteredInTargetApp && !TextDeliveryResult.sendFailed.enteredInTargetApp)
    }

    @Test func postProcessingNormalizesSpacingAndVocabulary() {
        #expect(TextPostProcessor.clean("  prism  한글  ", vocabulary: ["Prism"]) == "Prism 한글")
        #expect(TextPostProcessor.clean("use q5 and openai", vocabulary: ["Q5", "OpenAI", ""]) == "use Q5 and OpenAI")
        #expect(TextPostProcessor.clean("prisms", vocabulary: ["Prism"]) == "prisms")
        #expect(TextPostProcessor.clean("cost $5", vocabulary: ["$5"]) == "cost $5")
    }
}
