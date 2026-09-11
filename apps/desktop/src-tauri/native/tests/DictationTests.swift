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
        precondition(isolatedClipboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        print("PASS: native clipboard write/readback and transient history marker (isolated pasteboard; user clipboard unchanged)")
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
        for (mode, overridePaste, enter, expectedPaste) in [("copy", Optional<Bool>.none, false, false), ("paste", nil, false, true), ("copy", true, false, true), ("copy", true, true, true)] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var deliveries: [(Bool, Bool)] = []
            let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { _, paste, enter, _ in
                deliveries.append((paste, enter)); return paste ? .inserted : .copied
            })
            var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            value["whisperPath"] = executable.path; value["defaultDelivery"] = mode
            controller.toggle(fallbackPID: 0)
            controller.configure(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!, session: 1)
            try await Task.sleep(for: .milliseconds(30))
            controller.stop(pressEnter: enter, paste: overridePaste)
            for _ in 0..<100 { if !deliveries.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(deliveries.count == 1 && deliveries[0].0 == expectedPaste && deliveries[0].1 == enter)
            precondition(controller.phase == "idle" && controller.message.isEmpty, "Successful delivery must dismiss without a completion message")
            controller.cancel()
        }
        print("PASS: default copy/paste and explicit paste/send route independently (local process + delivery spy; no external insertion)")
        for outcome in [TextDeliveryResult.copied, .permissionRequired, .copyFailed, .unverified, .sendFailed] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var deliveries = 0
            let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { _, _, _, _ in
                deliveries += 1; return outcome
            })
            var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            value["whisperPath"] = executable.path; value["defaultDelivery"] = "paste"
            controller.toggle(fallbackPID: 0)
            controller.configure(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!, session: 1)
            try await Task.sleep(for: .milliseconds(30)); controller.stop()
            for _ in 0..<100 { if deliveries > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
            precondition(deliveries == 1 && controller.phase == "error")
            precondition(controller.message == outcome.fallbackMessage(controller.language) && !controller.message.isEmpty)
            controller.cancel()
        }
        print("PASS: missing target, denied permission, clipboard failure, unconfirmed insertion and send failure retain explicit error messages")
        for (refine, prompt, failure, cancel) in [(false,false,false,false), (true,false,false,false), (false,true,false,false), (true,true,false,false), (true,false,true,false), (true,true,false,true)] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var delivered: [String] = []
            let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { text, _, _, _ in delivered.append(text); return .inserted })
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
                if failure { precondition(!controller.message.isEmpty) }
                controller.cancel()
            }
        }
        for (mode, startPrompt, finishPrompt, expectedMode) in [("off",false,false,"none"), ("cleanup",false,false,"cleanup"), ("prompt",false,false,"none"), ("prompt",false,true,"prompt"), ("prompt",true,false,"none"), ("prompt",true,true,"prompt"), ("both",false,false,"cleanup"), ("both",false,true,"prompt"), ("both",true,false,"cleanup"), ("both",true,true,"prompt")] {
            let audio = temp.appendingPathComponent(UUID().uuidString + ".wav"); try Data([1,2,3]).write(to: audio)
            let recorder = FakeRecorder(); recorder.outputURL = audio
            var delivered: [String] = []; var didPaste = false
            let controller = DictationController(recorder: recorder, presentsOverlay: false, deliver: { text, paste, _, _ in delivered.append(text); didPaste = paste; return .inserted })
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
