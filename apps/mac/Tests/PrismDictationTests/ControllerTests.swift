import AppKit
import Testing
@testable import PrismDictation

/// Port of the controller flows in `native/tests/DictationTests.swift`. Fake recorder, fixture whisper-cli
/// executables and delivery spies: no microphone, network, clipboard changes or external insertion.
@MainActor
struct ControllerTests {
    private func start(_ controller: DictationController, _ settings: DictationSettings, promptMode: Bool = false) async throws {
        controller.toggle(fallbackPID: 0, promptMode: promptMode)
        controller.configure(DictationConfiguration(settings: settings), session: controller.generation)
        try await waitUntil { controller.phase == .recording }
    }

    @Test func toastsDismissWithoutHidingANewerSession() async throws {
        let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false, toastDuration: 0.02)
        controller.fail("microphone denied fixture")
        #expect(controller.overlayVisible && controller.phase == .error && controller.message == "microphone denied fixture")
        try await waitUntil { !controller.overlayVisible }
        #expect(!controller.overlayVisible)
        controller.fail("another fixture")
        controller.toggle(fallbackPID: 0)
        try await Task.sleep(for: .milliseconds(80))
        #expect(controller.overlayVisible && controller.phase == .preparing, "An older toast must never dismiss a newer session")
        controller.cancel()
        #expect(!controller.overlayVisible && controller.phase == .idle)
    }

    @Test func configurationFailureShowsItsMessage() {
        let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false)
        controller.toggle(fallbackPID: 0)
        controller.configurationFailed("Save an API key in dictation settings.", session: controller.generation)
        #expect(controller.phase == .error && controller.message == "Save an API key in dictation settings.")
    }

    @Test func staleConfigurationPendingMicrophoneAndDenialNeverRecord() async throws {
        let recorder = FakeRecorder()
        let controller = DictationController(recorder: recorder, presentsOverlay: false)
        controller.toggle(fallbackPID: 0)
        let session = controller.generation
        controller.cancel()
        controller.configure(DictationConfiguration(settings: localSettings()), session: session)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.phase == .idle && recorder.starts == 0)

        let pending = FakeRecorder()
        pending.delay = .seconds(1)
        let pendingController = DictationController(recorder: pending, presentsOverlay: false)
        pendingController.toggle(fallbackPID: 0)
        pendingController.configure(DictationConfiguration(settings: localSettings()), session: pendingController.generation)
        try await Task.sleep(for: .milliseconds(20))
        pendingController.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(pendingController.phase == .idle && pending.starts == 1)

        let denied = FakeRecorder()
        denied.denied = true
        let deniedController = DictationController(recorder: denied, presentsOverlay: false)
        deniedController.toggle(fallbackPID: 0)
        deniedController.configure(DictationConfiguration(settings: localSettings()), session: deniedController.generation)
        try await waitUntil { deniedController.phase == .error }
        #expect(deniedController.phase == .error)

        let recording = DictationController(recorder: FakeRecorder(), presentsOverlay: false)
        try await start(recording, localSettings())
        recording.cancel()
        #expect(recording.phase == .idle)
    }

    @Test func resolverStartsRecordingOrFailsWithItsError() async throws {
        let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false,
                                             resolve: { _ in DictationConfiguration(settings: localSettings()) })
        controller.toggle(fallbackPID: 0)
        try await waitUntil { controller.phase == .recording }
        #expect(controller.phase == .recording)
        controller.cancel()
        let failing = DictationController(recorder: FakeRecorder(), presentsOverlay: false,
                                          resolve: { _ in throw DictationError("Choose an executable whisper.cpp file.") })
        failing.toggle(fallbackPID: 0)
        try await waitUntil { failing.phase == .error }
        #expect(failing.message == "Choose an executable whisper.cpp file.")
    }

    @Test func recoveryKeepsInterruptedAudioAndText() async throws {
        let folder = TemporaryDirectory()
        let audio = try folder.file("interrupted.wav", contents: Data([1, 2, 3]))
        let recorder = FakeRecorder()
        recorder.running = true
        recorder.outputURL = audio
        let store = DictationRecoveryStore(directory: folder.url.appending(path: "interrupted"))
        let controller = DictationController(recorder: recorder, presentsOverlay: false, recovery: store)
        controller.fail("microphone disconnected")
        let entries = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        #expect(entries.count == 1 && FileManager.default.fileExists(atPath: entries[0].appending(path: "recording.wav").path))
        controller.cancel()
        #expect(FileManager.default.fileExists(atPath: entries[0].appending(path: "recording.wav").path))
    }

    @Test func subprocessFailureRetainsAudioAndUnavailableRecoveryBlocksTranscription() async throws {
        let folder = TemporaryDirectory()
        let failing = try folder.script("whisper-failure", "#!/bin/sh\nexit 1\n")
        for backupAvailable in [true, false] {
            let audio = try folder.file(UUID().uuidString + ".wav", contents: Data([1, 2, 3]))
            let recorder = FakeRecorder()
            recorder.outputURL = audio
            let store = DictationRecoveryStore(directory: folder.url.appending(path: UUID().uuidString))
            if !backupAvailable { try Data([0]).write(to: store.directory) }
            var delivered = 0
            let controller = DictationController(recorder: recorder, presentsOverlay: false, recovery: store,
                                                 deliver: { _, _, _, _, _ in delivered += 1; return .copied })
            var settings = localSettings(whisperPath: failing.path)
            settings.saveToClipboardHistory = false
            try await start(controller, settings)
            controller.stop()
            try await waitUntil { controller.phase == .error }
            #expect(controller.phase == .error && delivered == 0)
            controller.cancel()
            if backupAvailable {
                let entries = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                #expect(entries.count == 1 && FileManager.default.fileExists(atPath: entries[0].appending(path: "recording.wav").path))
            } else {
                #expect(FileManager.default.fileExists(atPath: audio.path), "A backup failure leaves the source recording intact")
            }
        }
    }

    @Test(arguments: [true, false])
    func defaultAndExplicitDeliveryRouteIndependently(saveHistory: Bool) async throws {
        let folder = TemporaryDirectory()
        let executable = try folder.whisperFixture()
        let cases: [(DefaultDelivery, Bool?, Bool, Bool)] = [(.copy, nil, false, false), (.paste, nil, false, true), (.copy, true, false, true), (.copy, true, true, true)]
        for (mode, overridePaste, enter, expectedPaste) in cases {
            let recorder = FakeRecorder()
            recorder.outputURL = try folder.file(UUID().uuidString + ".wav", contents: Data([1, 2, 3]))
            let store = DictationRecoveryStore(directory: folder.url.appending(path: UUID().uuidString))
            var deliveries: [(Bool, Bool, Bool)] = []
            var savedFirst = false
            let controller = DictationController(recorder: recorder, presentsOverlay: false, recovery: store, deliver: { _, paste, enter, _, history in
                savedFirst = store.latest()?.result == "local fixture transcript"
                deliveries.append((paste, enter, history))
                return paste ? .inserted : .copied
            })
            var settings = localSettings(whisperPath: executable.path)
            settings.defaultDelivery = mode
            settings.saveToClipboardHistory = saveHistory
            try await start(controller, settings)
            controller.stop(pressEnter: enter, paste: overridePaste)
            try await waitUntil { !deliveries.isEmpty && controller.phase == .idle }
            #expect(deliveries.count == 1 && deliveries[0].0 == expectedPaste && deliveries[0].1 == enter && deliveries[0].2 == saveHistory)
            #expect(savedFirst, "The result is saved before delivery")
            #expect(controller.phase == .idle && controller.message.isEmpty, "Successful delivery dismisses without a message")
            #expect(controller.lastTranscript == "local fixture transcript")
        }
    }

    @Test(arguments: [TextDeliveryResult.pasteSent, .copied, .permissionRequired, .copyFailed, .unverified, .sendFailed])
    func deliveryFailuresKeepExplicitMessages(outcome: TextDeliveryResult) async throws {
        let folder = TemporaryDirectory()
        let executable = try folder.whisperFixture()
        let recorder = FakeRecorder()
        recorder.outputURL = try folder.file("audio.wav", contents: Data([1, 2, 3]))
        var deliveries = 0
        let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { _, _, _, _, _ in deliveries += 1; return outcome })
        var settings = localSettings(whisperPath: executable.path)
        settings.defaultDelivery = .paste
        try await start(controller, settings)
        controller.stop()
        try await waitUntil { deliveries > 0 && controller.phase != .inserting && controller.phase != .transcribing }
        #expect(deliveries == 1 && controller.phase == (outcome == .pasteSent ? .idle : .error))
        if outcome == .pasteSent {
            #expect(controller.message.isEmpty, "Opaque paste delivery dismisses silently")
        } else {
            #expect(controller.message == outcome.fallbackMessage && !controller.message.isEmpty)
        }
        controller.cancel()
    }

    private struct ProcessingCase: Sendable, CustomTestStringConvertible {
        let refine: Bool, prompt: Bool, failure: Bool, cancel: Bool
        var testDescription: String { "refine \(refine) prompt \(prompt) failure \(failure) cancel \(cancel)" }
    }

    @Test(arguments: [ProcessingCase(refine: false, prompt: false, failure: false, cancel: false),
                      ProcessingCase(refine: true, prompt: false, failure: false, cancel: false),
                      ProcessingCase(refine: false, prompt: true, failure: false, cancel: false),
                      ProcessingCase(refine: true, prompt: true, failure: false, cancel: false),
                      ProcessingCase(refine: true, prompt: false, failure: true, cancel: false),
                      ProcessingCase(refine: true, prompt: true, failure: false, cancel: true)])
    private func legacyRefinementFallsBackAndIgnoresLateResults(_ test: ProcessingCase) async throws {
        let folder = TemporaryDirectory()
        let executable = try folder.whisperFixture()
        let recorder = FakeRecorder()
        recorder.outputURL = try folder.file("audio.wav", contents: Data([1, 2, 3]))
        let calls = CallLog()
        var delivered: [String] = []
        let controller = DictationController(recorder: recorder, presentsOverlay: false, process: { request in
            calls.append(request)
            if test.cancel { try? await Task.sleep(for: .seconds(5)) }
            return test.failure ? ProcessingResult(error: "fixture timeout") : ProcessingResult(text: "refined fixture")
        }, deliver: { text, _, _, _, _ in delivered.append(text); return .inserted })
        // Legacy settings: a single processing model and the refine switch, upgraded on load.
        var settings = localSettings(whisperPath: executable.path)
        settings.enhancementMode = nil
        settings.refineText = test.refine
        settings.processingModel = ProcessingSelection(provider: .vercel, model: "fixture/model")
        settings.upgrade()
        if !test.refine { settings.enhancementMode = .off }
        if test.prompt, !settings.mode.includes(.prompt) { settings.enhancementMode = settings.mode.toggling(.prompt) }
        try await start(controller, settings, promptMode: test.prompt)
        controller.stop()
        try await waitUntil { !delivered.isEmpty || (test.cancel && controller.phase == .processing && calls.count > 0) }
        #expect(calls.count == ((test.refine || test.prompt) ? 1 : 0))
        if test.refine || test.prompt { #expect(calls.first?.mode == (test.prompt ? .prompt : .cleanup)) }
        if test.cancel {
            #expect(controller.phase == .processing)
            let session = controller.generation
            controller.cancel()
            controller.processed(ProcessingResult(text: "late response must not paste"), session: session)
            try await Task.sleep(for: .milliseconds(30))
            #expect(delivered.isEmpty && controller.phase == .idle)
        } else {
            let refined = (test.refine || test.prompt) && !test.failure
            #expect(delivered == [refined ? "refined fixture" : "local fixture transcript"])
            #expect(controller.phase == .idle && controller.message.isEmpty, "Delivered text dismisses silently")
            #expect(controller.originalTranscript == "local fixture transcript")
        }
    }

    private struct ModeCase: Sendable, CustomTestStringConvertible {
        let mode: EnhancementMode, startPrompt: Bool, finishPrompt: Bool, expected: ProcessingMode?
        var testDescription: String { "\(mode) start \(startPrompt) finish \(finishPrompt)" }
    }

    @Test(arguments: [ModeCase(mode: .off, startPrompt: false, finishPrompt: false, expected: nil),
                      ModeCase(mode: .cleanup, startPrompt: false, finishPrompt: false, expected: .cleanup),
                      ModeCase(mode: .prompt, startPrompt: false, finishPrompt: false, expected: nil),
                      ModeCase(mode: .prompt, startPrompt: false, finishPrompt: true, expected: .prompt),
                      ModeCase(mode: .prompt, startPrompt: true, finishPrompt: false, expected: nil),
                      ModeCase(mode: .prompt, startPrompt: true, finishPrompt: true, expected: .prompt),
                      ModeCase(mode: .both, startPrompt: false, finishPrompt: false, expected: .cleanup),
                      ModeCase(mode: .both, startPrompt: false, finishPrompt: true, expected: .prompt),
                      ModeCase(mode: .both, startPrompt: true, finishPrompt: false, expected: .cleanup),
                      ModeCase(mode: .both, startPrompt: true, finishPrompt: true, expected: .prompt)])
    private func enhancementModesUseTheirOwnProfiles(_ test: ModeCase) async throws {
        let folder = TemporaryDirectory()
        let executable = try folder.whisperFixture()
        let recorder = FakeRecorder()
        recorder.outputURL = try folder.file("audio.wav", contents: Data([1, 2, 3]))
        let calls = CallLog()
        var delivered: [String] = []
        var didPaste = false
        let controller = DictationController(recorder: recorder, presentsOverlay: false, process: { request in
            calls.append(request)
            return ProcessingResult(text: "edited")
        }, deliver: { text, paste, _, _, _ in delivered.append(text); didPaste = paste; return .inserted })
        var settings = localSettings(whisperPath: executable.path)
        settings.enhancementMode = test.mode
        settings.defaultDelivery = .copy
        settings.cleanupModel = ProcessingSelection(provider: .vercel, model: "fixture/cleanup")
        settings.promptModel = ProcessingSelection(provider: .openai, model: "fixture/prompt")
        settings.cleanupInstruction = "Custom instructions for cleanup"
        settings.promptInstruction = "Custom instructions for prompt"
        settings.upgrade()
        try await start(controller, settings, promptMode: test.startPrompt)
        controller.toggle(fallbackPID: 0, promptMode: test.finishPrompt)
        try await waitUntil { !delivered.isEmpty }
        #expect(delivered == [test.expected == nil ? "local fixture transcript" : "edited"])
        #expect(didPaste == test.finishPrompt, "The prompt shortcut pastes even when the default is copy")
        #expect(calls.count == (test.expected == nil ? 0 : 1))
        if let expected = test.expected, let call = calls.first {
            #expect(call.mode == expected)
            #expect(call.instruction == "Custom instructions for \(expected.rawValue)")
            #expect(call.selection.model == "fixture/\(expected.rawValue)")
        }
    }

    @Test func missingProcessingModelDeliversTheOriginal() async throws {
        let folder = TemporaryDirectory()
        let executable = try folder.whisperFixture()
        let recorder = FakeRecorder()
        recorder.outputURL = try folder.file("audio.wav", contents: Data([1, 2, 3]))
        var delivered: [String] = []
        let controller = DictationController(recorder: recorder, presentsOverlay: false, process: { _ in ProcessingResult(text: "never") },
                                             deliver: { text, _, _, _, _ in delivered.append(text); return .inserted })
        var settings = localSettings(whisperPath: executable.path)
        settings.enhancementMode = .cleanup
        try await start(controller, settings)
        controller.stop()
        try await waitUntil { !delivered.isEmpty }
        #expect(delivered == ["local fixture transcript"])
    }

    @Test func stalePromptShortcutDoesNotStopWhenPromptIsOff() async throws {
        let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false)
        try await start(controller, localSettings())
        controller.stop(paste: true, processAsPrompt: true)
        #expect(controller.phase == .recording)
        controller.cancel()
    }

    @Test func cancellationDuringTranscriptionStopsDeliveryAndRemovesAudio() async throws {
        let folder = TemporaryDirectory()
        let waiting = try folder.script("whisper-wait", "#!/bin/sh\nexec /bin/sleep 10\n")
        let audio = try folder.file("cancel.wav", contents: Data([1, 2, 3]))
        let recorder = FakeRecorder()
        recorder.outputURL = audio
        var delivered = 0
        let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { _, _, _, _, _ in delivered += 1; return .copied })
        try await start(controller, localSettings(whisperPath: waiting.path))
        controller.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .transcribing)
        controller.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.phase == .idle && delivered == 0)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func recordingHintsFollowRegisteredKeysAndPreview() {
        let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false)
        var settings = DictationSettings()
        settings.defaultDelivery = .copy
        controller.preview(settings: settings, controls: RecordingControlSettings(settings: settings, primary: .doubleModifier(.control)))
        #expect(controller.phase == .preview && controller.displayedPhase == .recording)
        #expect(controller.recordingHints.map(\.key) == ["Esc", "⌃ ⌃", "Return"])
        #expect(controller.recordingHints.map(\.label) == ["Cancel", "Copy", "Send"], "Paste follows a copy default")
        controller.cancel()
        #expect(controller.recordingHints.map(\.key) == ["⌃ ⌃"], "Outside a preview only same-as-start paste remains")
    }

    @Test func restoresTheLatestTranscriptAfterRestart() throws {
        let folder = TemporaryDirectory()
        let store = DictationRecoveryStore(directory: folder.url.appending(path: "recovery"))
        let entry = try store.preserve(try folder.file("a.wav"))
        try store.save("원문 👋", named: "original.txt", in: entry)
        try store.save("결과 👋", named: "result.txt", in: entry)
        let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false, recovery: store)
        #expect(controller.originalTranscript == "원문 👋" && controller.lastTranscript == "결과 👋")
    }
}

/// Collects processing requests from the nonisolated processor closure.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ProcessingRequest] = []

    func append(_ request: ProcessingRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    var first: ProcessingRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.first
    }
}
