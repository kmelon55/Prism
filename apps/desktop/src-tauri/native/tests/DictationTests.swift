import AppKit
import AVFoundation
import Foundation

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    static var status = 200
    static var response = Data("{\"text\":\"fixture transcript\"}".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class FakeRecorder: DictationRecording {
    var onLevel: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts = 0
    var stops = 0
    var delay: Double = 0
    var denied = false
    var running = false
    var outputURL: URL?
    func start() async throws {
        starts += 1
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if denied { throw DictationFailure("microphone denied fixture") }
        running = true
    }
    func stop() -> URL? { stops += 1; guard running else { return nil }; running = false; return outputURL }
}
@MainActor private enum HistoryFixture {
    static var saved: [String] = []
    static func event(_ pointer: UnsafePointer<CChar>) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any], event["action"] as? String == "save-history", let text = event["transcript"] as? String else { return }
        saved.append(text)
    }
}
@MainActor private enum ProcessingFixture {
    static weak var controller: DictationController?
    static var calls: [[String: Any]] = []
    static var hold = false
    static var result = ProcessingResult(text: "refined fixture")
    static func event(_ pointer: UnsafePointer<CChar>) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any], event["action"] as? String == "process" else { return }
        calls.append(event)
        if !hold { controller?.processed(result, session: UInt64(event["session"] as! Int)) }
    }
}
@main struct DictationTests {
    @MainActor static func main() async throws {
        let catalog = NativeMessages(json: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
        let oldKeyError = "저장된 키를 사용하려면 설정에서 ‘키 사용 허용’을 눌러 주세요."
        let englishKeyError = catalog.translate(oldKeyError, english: true)
        precondition(englishKeyError != oldKeyError && englishKeyError.contains("Allow key use"))
        let deniedKeyError = "Keychain access was denied. Try again and approve access in the macOS dialog."
        precondition(catalog.translate(deniedKeyError, english: false).contains("키체인 접근이 거부"))
        precondition(catalog.translate("Could not read the saved key (macOS error -36).", english: false) == "저장된 키를 읽지 못했습니다(macOS 오류 -36).")
        precondition(catalog.translate("fixture-provider-detail", english: true) == "fixture-provider-detail")
        // A dismissed microphone error must not reappear when another window syncs its locale.
        let toastController = DictationController(recorder: FakeRecorder(), presentsOverlay: false, toastDuration: 0.02)
        toastController.fail("microphone denied fixture")
        precondition(toastController.overlayVisible)
        try await Task.sleep(for: .milliseconds(60))
        precondition(!toastController.overlayVisible)
        toastController.setUILanguage("ko")
        precondition(!toastController.overlayVisible && toastController.phase == "error")
        // An older toast must never dismiss a newer recording session.
        toastController.fail("another fixture")
        toastController.toggle(fallbackPID: 0)
        try await Task.sleep(for: .milliseconds(60))
        precondition(toastController.overlayVisible && toastController.phase == "preparing")
        toastController.cancel()
        precondition(!toastController.overlayVisible)
        let languageController = DictationController(recorder: FakeRecorder(), presentsOverlay: false)
        languageController.messages = catalog
        languageController.setUILanguage("en")
        languageController.toggle(fallbackPID: 0)
        languageController.configurationFailed(oldKeyError, session: 1)
        precondition(languageController.phase == "error" && languageController.message == englishKeyError)
        languageController.setUILanguage("ko")
        precondition(languageController.message == oldKeyError)
        languageController.cancel()
        print("PASS: shared native translations, status codes, first-use configuration failure and live language changes")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("prism-dictation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let wav = temp.appendingPathComponent("fixture.wav")
        try Data([82, 73, 70, 70, 0, 0, 0, 0, 87, 65, 86, 69]).write(to: wav)
        let recovery = DictationRecoveryStore(directory: temp.appendingPathComponent("recovery"))
        let first = try recovery.preserve(wav)
        let savedAudio = try Data(contentsOf: first.appendingPathComponent("recording.wav"))
        precondition(savedAudio == (try? Data(contentsOf: wav)))
        let longText = String(repeating: "1분 넘게 말한 한국어 👋\n", count: 500)
        try recovery.save(longText, named: "original.txt", in: first)
        precondition(recovery.latest()?.result == longText, "Original remains recoverable if processing crashes")
        try recovery.save("processed " + longText, named: "result.txt", in: first)
        try recovery.finish(first)
        precondition(!FileManager.default.fileExists(atPath: first.appendingPathComponent("recording.wav").path))
        let second = try recovery.preserve(wav)
        precondition(first != second && FileManager.default.fileExists(atPath: second.appendingPathComponent("recording.wav").path))
        let reopened = DictationRecoveryStore(directory: recovery.directory)
        precondition(reopened.latest()?.original == longText && reopened.latest()?.result == "processed " + longText,
            "A later failed recording and process restart must not erase previous text")
        for (url, mode) in [(recovery.directory, 0o700), (first, 0o700), (first.appendingPathComponent("original.txt"), 0o600), (second.appendingPathComponent("recording.wav"), 0o600)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            precondition(permissions?.intValue == mode)
        }
        let interruptedAudio = temp.appendingPathComponent("interrupted.wav")
        try Data([1,2,3]).write(to: interruptedAudio)
        let interruptedRecorder = FakeRecorder(); interruptedRecorder.running = true; interruptedRecorder.outputURL = interruptedAudio
        let interruptedStore = DictationRecoveryStore(directory: temp.appendingPathComponent("interrupted"))
        let interruptedController = DictationController(recorder: interruptedRecorder, presentsOverlay: false, recovery: interruptedStore)
        interruptedController.fail("microphone disconnected")
        let interruptedEntries = try FileManager.default.contentsOfDirectory(at: interruptedStore.directory, includingPropertiesForKeys: nil)
        precondition(interruptedEntries.count == 1 && FileManager.default.fileExists(atPath: interruptedEntries[0].appendingPathComponent("recording.wav").path))
        interruptedController.cancel()
        precondition(FileManager.default.fileExists(atPath: interruptedEntries[0].appendingPathComponent("recording.wav").path))
        print("PASS: long Unicode text, processing interruption, later failed recording, restart recovery, private file modes and microphone failure audio")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = RemoteTranscriptionService(session: session)
        for (provider, base, suffix) in [(RemoteProvider.openAI, "https://fixture.invalid/v1", "/audio/transcriptions"), (.groq, "https://fixture.invalid/openai/v1", "/audio/transcriptions"), (.custom, "http://127.0.0.1:9876/v1", "/audio/transcriptions"), (.xAI, "https://fixture.invalid/v1", "/stt"), (.vercel, "https://fixture.invalid/v4/ai", "/transcription-model")] {
            let text = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: provider, apiKey: "fixture-key", baseURL: base, model: "openai/whisper-1"), language: "ko", prompt: "fixture hint", vocabulary: ["Prism"])
            precondition(text == "fixture transcript")
            let request = MockProtocol.requests.last!
            precondition(request.url!.path.hasSuffix(suffix))
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            if provider == .vercel { precondition(request.value(forHTTPHeaderField: "ai-model-id") == "openai/whisper-1") }
        }
        print("PASS: all five remote provider contracts (URLProtocol mock; no network)")
        _ = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: .openAI, apiKey: "fixture-key", baseURL: "https://fixture.invalid/v1", model: "gpt-transcribe"), language: "ko", prompt: "hint", vocabulary: [])
        let currentRequest = MockProtocol.requests.last!
        var requestBody = currentRequest.httpBody ?? Data()
        if let stream = currentRequest.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; requestBody.append(contentsOf: bytes.prefix(count))
            }
        }
        let multipart = String(decoding: requestBody, as: UTF8.self)
        precondition(multipart.contains("name=\"languages[]\""))
        precondition(!multipart.contains("name=\"language\""))
        print("PASS: current OpenAI file transcription language-array contract (no network)")
        MockProtocol.status = 401
        MockProtocol.response = Data("{\"error\":{\"message\":\"fixture-secret\"}}".utf8)
        do {
            _ = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: .openAI, apiKey: "fixture-key", baseURL: "https://fixture.invalid/v1", model: "whisper-1"), language: "auto", prompt: "", vocabulary: [])
            preconditionFailure("Expected provider failure")
        } catch { precondition(!error.localizedDescription.contains("fixture-secret")) }
        MockProtocol.status = 200; MockProtocol.response = Data("{}".utf8)
        do {
            _ = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: .openAI, apiKey: "fixture-key", baseURL: "https://fixture.invalid/v1", model: "whisper-1"), language: "auto", prompt: "", vocabulary: [])
            preconditionFailure("Expected invalid response")
        } catch {}
        print("PASS: provider error redaction and invalid transcript response")
        let isolatedClipboard = NSPasteboard.withUniqueName()
        defer { isolatedClipboard.releaseGlobally() }
        precondition(TextInjector.copy("복구할 받아쓰기 👋", to: isolatedClipboard))
        precondition(isolatedClipboard.string(forType: .string) == "복구할 받아쓰기 👋")
        precondition(isolatedClipboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != true)
        precondition(TextInjector.copy("비공개 받아쓰기 👋", to: isolatedClipboard, saveToHistory: false))
        precondition(isolatedClipboard.string(forType: .string) == "비공개 받아쓰기 👋")
        precondition(isolatedClipboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        precondition(TextInjector.copy("기록 다시 켜기", to: isolatedClipboard))
        precondition(isolatedClipboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != true)
        print("PASS: native clipboard write/readback without history exclusion (isolated pasteboard; user clipboard unchanged)")
        let app = NSRunningApplication.current
        let target = TextInsertionTarget(processIdentifier: ProcessInfo.processInfo.processIdentifier, focusedElement: nil, application: app)
        var posted: [String] = []
        var foreground: pid_t? = target.processIdentifier
        var pasteboardRevision = 1
        let environment = TextInjector.Environment(running: { _ in true }, permission: { true }, frontmostPID: { foreground },
            activate: { _ in }, focused: { _ in nil },
            paste: { _ in posted.append("paste"); return true },
            enter: { _ in posted.append("enter"); return true }, revision: { pasteboardRevision })
        let opaqueResult = await TextInjector.deliver("long transcript", paste: true, pressEnterAfterPaste: true,
            target: target, copyText: { _ in true }, environment: environment)
        precondition(opaqueResult == .pasteSent && posted == ["paste", "enter"], "Missing AX focus must not block keyboard delivery: \(opaqueResult), \(posted)")
        posted = []; foreground = -1
        let lostFocus = await TextInjector.deliver("long transcript", paste: true, pressEnterAfterPaste: true,
            target: target, copyText: { _ in true }, environment: environment)
        precondition(lostFocus == .copied && posted.isEmpty, "Do not paste into a different foreground application")
        foreground = target.processIdentifier
        let changeClipboard = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30)); pasteboardRevision += 1
        }
        let racedResult = await TextInjector.deliver("long transcript", paste: true, pressEnterAfterPaste: true,
            target: target, copyText: { _ in true }, environment: environment)
        await changeClipboard.value
        precondition(racedResult == .copied && posted.isEmpty, "Do not paste a clipboard replaced during delivery")
        precondition(TextInjector.pasteResult(observable: true, confirmed: false) == .unverified)
        precondition(TextInjector.pasteResult(observable: true, confirmed: true) == .pasted)
        precondition(!TextDeliveryResult.pasteSent.enteredInTargetApp, "Posted events are not proof of insertion")
        print("PASS: complete keyboard delivery without AX, explicit send, focus loss and clipboard races (event spies; no external input)")
        var clipboardWrites: [String] = []
        let noTargetResult = await TextInjector.deliver("recoverable transcript", paste: true, pressEnterAfterPaste: false, target: nil, copyText: {
            clipboardWrites.append($0); return true
        })
        precondition(clipboardWrites == ["recoverable transcript"])
        precondition(noTargetResult == .copied || noTargetResult == .permissionRequired)
        let failedCopy = await TextInjector.deliver("recoverable transcript", paste: true, pressEnterAfterPaste: true, target: nil, copyText: { _ in false })
        precondition(failedCopy == .copyFailed)
        let copyOnly = await TextInjector.deliver("copy only", paste: false, pressEnterAfterPaste: false, target: nil, copyText: {
            clipboardWrites.append($0); return true
        })
        precondition(copyOnly == .copied && clipboardWrites.last == "copy only")
        let cancelledDelivery = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await TextInjector.deliver("cancelled", paste: false, pressEnterAfterPaste: false, target: nil, copyText: {
                clipboardWrites.append($0); return true
            })
        }
        _ = await cancelledDelivery.value
        precondition(!clipboardWrites.contains("cancelled"))
        let expectation = TextInsertionExpectation(value: "안녕 👋 world", range: CFRange(location: 6, length: 5), text: "Prism")!
        precondition(expectation.confirms("안녕 👋 Prism"))
        precondition(!expectation.confirms("안녕 👋 world") && !expectation.confirms(nil))
        precondition(!expectation.confirms("Prism"))
        precondition(TextInsertionExpectation(value: "same", range: CFRange(location: 0, length: 4), text: "same")?.confirms("same") == false)
        precondition(TextInsertionExpectation(value: "a", range: CFRange(location: 2, length: 0), text: "b") == nil)
        precondition(TextInsertionExpectation(value: "a", range: CFRange(location: 0, length: Int.max), text: "b") == nil)
        precondition(!TextDeliveryResult.unverified.enteredInTargetApp && !TextDeliveryResult.sendFailed.enteredInTargetApp)
        print("PASS: clipboard backup without a target, copy failure, cancellation, and verified UTF-16 insertion (spies; no clipboard changes or external insertion)")
        precondition(TextPostProcessor.clean("  prism  한글  ", vocabulary: ["Prism"]) == "Prism 한글")
        let json = """
        {"provider":"local","model":"","baseURL":"","language":"auto","prompt":"","vocabulary":[],"whisperPath":"/fixture","modelPath":"/fixture.bin","uiLanguage":"en","apiKey":""}
        """
        // A valid but stale dictation configuration must not override the app language.
        languageController.setUILanguage("en")
        languageController.toggle(fallbackPID: 0)
        languageController.configure(json.replacingOccurrences(of: "\"uiLanguage\":\"en\"", with: "\"uiLanguage\":\"ko\""), session: 3)
        precondition(languageController.language.english)
        languageController.cancel()
        let recorder = FakeRecorder()
        let controller = DictationController(recorder: recorder, presentsOverlay: false)
        controller.toggle(fallbackPID: 0)
        precondition(controller.phase == "preparing")
        controller.cancel()
        controller.configure(json, session: 1)
        try await Task.sleep(for: .milliseconds(30))
        precondition(controller.phase == "idle" && recorder.starts == 0)
        let pending = FakeRecorder(); pending.delay = 1
        let pendingController = DictationController(recorder: pending, presentsOverlay: false)
        pendingController.toggle(fallbackPID: 0); pendingController.configure(json, session: 1)
        try await Task.sleep(for: .milliseconds(20)); pendingController.cancel()
        try await Task.sleep(for: .milliseconds(30))
        precondition(pendingController.phase == "idle" && pending.starts == 1)
        let denied = FakeRecorder(); denied.denied = true
        let deniedController = DictationController(recorder: denied, presentsOverlay: false)
        deniedController.toggle(fallbackPID: 0); deniedController.configure(json, session: 1)
        try await Task.sleep(for: .milliseconds(30))
        precondition(deniedController.phase == "error")
        deniedController.cancel()
        let recording = FakeRecorder()
        let recordingController = DictationController(recorder: recording, presentsOverlay: false)
        recordingController.toggle(fallbackPID: 0); recordingController.configure(json, session: 1)
        try await Task.sleep(for: .milliseconds(30)); precondition(recordingController.phase == "recording")
        recordingController.cancel(); precondition(recordingController.phase == "idle")
        precondition(MockProtocol.requests.count == 8)
        print("PASS: stale configuration, pending microphone cancellation, permission denial, recording cancellation; no STT triggered")
        let executable = temp.appendingPathComponent("whisper-fixture")
        try "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = \"-of\" ]; then shift; printf 'local fixture transcript' > \"$1.txt\"; fi; shift; done\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let local = try await LocalWhisperService().transcribe(audioURL: wav, executableURL: executable, modelURL: temp.appendingPathComponent("model.bin"), language: "auto", prompt: "")
        precondition(local == "local fixture transcript")
        precondition(!FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("transcript.txt").path))
        print("PASS: local process result and temporary transcript cleanup (fixture executable)")
        let failedExecutable = temp.appendingPathComponent("whisper-failure")
        try "#!/bin/sh\nexit 1\n".write(to: failedExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failedExecutable.path)
        for backupAvailable in [true, false] {
            let failedAudio = temp.appendingPathComponent(UUID().uuidString + ".wav")
            try Data([1,2,3]).write(to: failedAudio)
            let failedRecorder = FakeRecorder(); failedRecorder.outputURL = failedAudio
            let failedStore = DictationRecoveryStore(directory: temp.appendingPathComponent(UUID().uuidString))
            if !backupAvailable { try Data([0]).write(to: failedStore.directory) }
            let failedController = DictationController(recorder: failedRecorder, presentsOverlay: false, recovery: failedStore,
                deliver: { _, _, _, _, _ in preconditionFailure("Failed transcription must not deliver") })
            var failureConfig = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            failureConfig["whisperPath"] = failedExecutable.path
            failureConfig["saveToClipboardHistory"] = false
            failedController.toggle(fallbackPID: 0)
            failedController.configure(String(data: try JSONSerialization.data(withJSONObject: failureConfig), encoding: .utf8)!, session: 1)
            try await Task.sleep(for: .milliseconds(30)); failedController.stop()
            for _ in 0..<100 { if failedController.phase == "error" { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(failedController.phase == "error")
            failedController.cancel()
            if backupAvailable {
                let entries = try FileManager.default.contentsOfDirectory(at: failedStore.directory, includingPropertiesForKeys: nil)
                precondition(entries.count == 1 && FileManager.default.fileExists(atPath: entries[0].appendingPathComponent("recording.wav").path))
            } else {
                precondition(FileManager.default.fileExists(atPath: failedAudio.path), "Backup failure must leave the source recording intact")
            }
        }
        print("PASS: real local subprocess failure retains audio; unavailable recovery storage preserves the source and blocks transcription")

        for saveHistory in [true, false] {
            for (mode, overridePaste, enter, expectedPaste) in [("copy", Optional<Bool>.none, false, false), ("paste", nil, false, true), ("copy", true, false, true), ("copy", true, true, true)] {
                let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
                let recorder = FakeRecorder(); recorder.outputURL = audio
                var deliveries: [(Bool, Bool)] = []
                let store = DictationRecoveryStore(directory: temp.appendingPathComponent(UUID().uuidString))
                HistoryFixture.saved = []
                let controller = DictationController(recorder: recorder, presentsOverlay: false, recovery: store, deliver: { _, paste, enter, _, history in
                    precondition(history == saveHistory)
                    precondition(store.latest()?.result == "local fixture transcript")
                    precondition(HistoryFixture.saved == (saveHistory ? ["local fixture transcript"] : []))
                    deliveries.append((paste, enter)); return paste ? .inserted : .copied
                })
                var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
                value["whisperPath"] = executable.path; value["defaultDelivery"] = mode
                value["saveToClipboardHistory"] = saveHistory
                controller.callback = { pointer in MainActor.assumeIsolated { HistoryFixture.event(pointer) } }
                controller.toggle(fallbackPID: 0)
                controller.configure(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!, session: 1)
                try await Task.sleep(for: .milliseconds(30))
                controller.stop(pressEnter: enter, paste: overridePaste)
                for _ in 0..<100 { if !deliveries.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
                precondition(deliveries.count == 1 && deliveries[0].0 == expectedPaste && deliveries[0].1 == enter)
                precondition(controller.phase == "idle" && controller.message.isEmpty, "Successful delivery must dismiss without a completion message")
                controller.cancel()
            }
        }
        print("PASS: default copy/paste and explicit paste/send route independently (local process + delivery spy; no external insertion)")
        for outcome in [TextDeliveryResult.pasteSent, .copied, .permissionRequired, .copyFailed, .unverified, .sendFailed] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var deliveries = 0
            let outcomeRecovery = DictationRecoveryStore(directory: temp.appendingPathComponent(UUID().uuidString))
            let controller = DictationController(recorder: recorder, presentsOverlay: false, recovery: outcomeRecovery, deliver: { _, _, _, _, _ in
                precondition(outcomeRecovery.latest()?.result == "local fixture transcript", "Save the result before attempting delivery")
                deliveries += 1; return outcome
            })
            var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            value["whisperPath"] = executable.path; value["defaultDelivery"] = "paste"
            controller.toggle(fallbackPID: 0)
            controller.configure(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!, session: 1)
            try await Task.sleep(for: .milliseconds(30)); controller.stop()
            for _ in 0..<100 { if deliveries > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(deliveries == 1 && controller.phase == (outcome == .pasteSent ? "idle" : "error"))
            if outcome == .pasteSent {
                precondition(controller.message.isEmpty, "Opaque paste delivery must dismiss without a completion or recovery notice")
            } else { precondition(controller.message == outcome.fallbackMessage(controller.language) && !controller.message.isEmpty) }
            controller.cancel()
        }
        print("PASS: missing target, denied permission, clipboard failure, unconfirmed insertion and send failure retain explicit error messages")
        for (refine, prompt, failure, cancel) in [(false,false,false,false), (true,false,false,false), (false,true,false,false), (true,true,false,false), (true,false,true,false), (true,true,false,true)] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var delivered: [String] = []
            let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { text, _, _, _, _ in delivered.append(text); return .inserted })
            ProcessingFixture.controller = controller; ProcessingFixture.calls = []; ProcessingFixture.hold = cancel
            ProcessingFixture.result = failure ? ProcessingResult(error: "fixture timeout") : ProcessingResult(text: "refined fixture")
            controller.callback = { pointer in MainActor.assumeIsolated { ProcessingFixture.event(pointer) } }
            var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            value["whisperPath"] = executable.path; value["refineText"] = refine
            value["processingModel"] = ["provider":"vercel", "model":"fixture/model"]
            controller.toggle(fallbackPID: 0, promptMode: prompt)
            controller.configure(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!, session: 1)
            try await Task.sleep(for: .milliseconds(30)); controller.stop()
            for _ in 0..<100 { if !delivered.isEmpty || (cancel && controller.phase == "processing") { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(ProcessingFixture.calls.count == ((refine || prompt) ? 1 : 0))
            if refine || prompt { precondition(ProcessingFixture.calls[0]["processingMode"] as? String == (prompt ? "prompt" : "cleanup")) }
            if cancel {
                precondition(controller.phase == "processing"); controller.cancel()
                controller.processed(ProcessingResult(text: "late response must not paste"), session: 1)
                try await Task.sleep(for: .milliseconds(30))
                precondition(delivered.isEmpty && controller.phase == "idle")
            } else {
                precondition(delivered == [(!refine && !prompt) || failure ? "local fixture transcript" : "refined fixture"])
                precondition(controller.phase == "idle" && controller.message.isEmpty, "Delivered original or refined text must dismiss silently")
                controller.cancel()
            }
        }
        for (mode, startPrompt, finishPrompt, expectedMode) in [("off",false,false,"none"), ("cleanup",false,false,"cleanup"), ("prompt",false,false,"none"), ("prompt",false,true,"prompt"), ("prompt",true,false,"none"), ("prompt",true,true,"prompt"), ("both",false,false,"cleanup"), ("both",false,true,"prompt"), ("both",true,false,"cleanup"), ("both",true,true,"prompt")] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var delivered: [String] = []; var didPaste = false
            let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { text, paste, _, _, _ in delivered.append(text); didPaste = paste; return .inserted })
            ProcessingFixture.controller = controller; ProcessingFixture.calls = []; ProcessingFixture.hold = false
            ProcessingFixture.result = ProcessingResult(text: "edited")
            controller.callback = { pointer in MainActor.assumeIsolated { ProcessingFixture.event(pointer) } }
            var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            value["whisperPath"] = executable.path; value["enhancementMode"] = mode; value["defaultDelivery"] = "copy"
            value["cleanupModel"] = ["provider":"vercel", "model":"fixture/cleanup"]
            value["promptModel"] = ["provider":"openai", "model":"fixture/prompt"]
            value["cleanupInstruction"] = "Custom instructions for cleanup"
            value["promptInstruction"] = "Custom instructions for prompt"
            controller.toggle(fallbackPID: 0, promptMode: startPrompt)
            controller.configure(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!, session: 1)
            try await Task.sleep(for: .milliseconds(30))
            controller.toggle(fallbackPID: 0, promptMode: finishPrompt)
            for _ in 0..<100 { if !delivered.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(delivered == [expectedMode == "none" ? "local fixture transcript" : "edited"])
            precondition(didPaste == finishPrompt, "Prompt shortcut must paste even when default is copy")
            precondition(ProcessingFixture.calls.count == (expectedMode == "none" ? 0 : 1))
            if expectedMode != "none" {
                precondition(ProcessingFixture.calls[0]["processingMode"] as? String == expectedMode)
                precondition(ProcessingFixture.calls[0]["processingPrompt"] as? String == "Custom instructions for " + expectedMode)
                precondition((ProcessingFixture.calls[0]["processingModel"] as? [String:Any])?["model"] as? String == "fixture/" + expectedMode)
            }
            controller.cancel()
        }
        print("PASS: independent enhancement modes, prompt override during ordinary recording, cleanup or raw exit from prompt recording, per-profile instructions and explicit paste")
        var receipt = UsageReceipt()
        receipt.add(UsageMeasurement(inputTokens: 100, outputTokens: 20, costUsd: 0.00001, costKind: "estimated"))
        receipt.add(UsageMeasurement(costKind: "unknown"))
        precondition(receipt.label(AppLanguage(english: true)).contains("<$0.0001 + ?"))
        precondition(receipt.label(AppLanguage(english: true)).contains("120 tokens"))
        print("PASS: refinement switch, separate prompt mode, single processing call, original fallback, cancellation and stale response (no network)")
        let waitingExecutable = temp.appendingPathComponent("whisper-wait-fixture")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: waitingExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: waitingExecutable.path)
        let cancellableAudio = temp.appendingPathComponent("cancel.wav")
        try Data([1, 2, 3]).write(to: cancellableAudio)
        let transcribingRecorder = FakeRecorder(); transcribingRecorder.outputURL = cancellableAudio
        let transcribingController = DictationController(recorder: transcribingRecorder, presentsOverlay: false)
        var localConfiguration = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        localConfiguration["whisperPath"] = waitingExecutable.path
        transcribingController.toggle(fallbackPID: 0)
        transcribingController.configure(String(data: try JSONSerialization.data(withJSONObject: localConfiguration), encoding: .utf8)!, session: 1)
        try await Task.sleep(for: .milliseconds(30))
        transcribingController.stop()
        try await Task.sleep(for: .milliseconds(50))
        precondition(transcribingController.phase == "transcribing")
        transcribingController.cancel()
        try await Task.sleep(for: .milliseconds(80))
        precondition(transcribingController.phase == "idle")
        precondition(!FileManager.default.fileExists(atPath: cancellableAudio.path))
        print("PASS: cancellation during transcription stops delivery and removes temporary audio")
        print("Native microphone status: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue); Accessibility: \(AXIsProcessTrusted())")
        print("Microphone capture and external-app insertion were not exercised by this mock suite.")
    }
}
