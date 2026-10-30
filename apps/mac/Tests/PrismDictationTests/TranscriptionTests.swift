import Foundation
import PrismKit
import Testing
@testable import PrismDictation

/// Provider request contracts against a URLProtocol mock, local whisper-cli fixtures, text processing,
/// recovery and the usage ledger. No network, paid requests or real inference.
struct TranscriptionTests {
    @Test(arguments: [(SpeechProvider.openai, "/audio/transcriptions"), (.groq, "/audio/transcriptions"), (.custom, "/audio/transcriptions"),
                      (.xai, "/stt"), (.vercel, "/transcription-model")])
    func remoteProviderContracts(provider: SpeechProvider, suffix: String) async throws {
        let folder = TemporaryDirectory()
        let wav = try folder.file("fixture.wav")
        let host = "stt-\(provider.rawValue).invalid"
        MockHTTP.serve(host, .init(body: Data(#"{"text":"fixture transcript","usage":{"input_tokens":5,"output_tokens":2,"cost":0.001}}"#.utf8)))
        let service = RemoteTranscriptionService(session: MockHTTP.session())
        let result = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: provider, apiKey: "fixture-key",
                                                  baseURL: "https://\(host)/v1", model: "openai/whisper-1"),
                                                  language: "ko", prompt: "fixture hint", vocabulary: ["Prism"])
        #expect(result.text == "fixture transcript")
        #expect(result.usage.costUSD == 0.001 && result.usage.costKind == "reported" && result.usage.inputTokens == 5)
        let request = try #require(MockHTTP.requests(for: host).last)
        #expect(request.url?.path.hasSuffix(suffix) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        switch provider {
        case .vercel:
            #expect(request.value(forHTTPHeaderField: "ai-model-id") == "openai/whisper-1")
            #expect(body.contains("\"providerOptions\""))
        case .xai:
            #expect(body.contains("name=\"keyterm\"") && !body.contains("name=\"model\""))
            #expect(body.range(of: "name=\"file\"")!.lowerBound > body.range(of: "name=\"keyterm\"")!.lowerBound, "xAI needs the file last")
        default:
            #expect(body.contains("name=\"model\"") && body.contains("name=\"language\""))
        }
    }

    @Test func currentOpenAIModelsUseTheLanguageArray() async throws {
        let folder = TemporaryDirectory()
        MockHTTP.serve("stt-languages.invalid", .init(body: Data(#"{"text":"ok"}"#.utf8)))
        _ = try await RemoteTranscriptionService(session: MockHTTP.session()).transcribe(
            audioURL: try folder.file("a.wav"),
            configuration: RemoteConfiguration(provider: .openai, apiKey: "k", baseURL: "https://stt-languages.invalid/v1", model: "gpt-transcribe"),
            language: "ko", prompt: "hint", vocabulary: [])
        let body = String(decoding: MockHTTP.requests(for: "stt-languages.invalid").last?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"languages[]\"") && !body.contains("name=\"language\""))
    }

    @Test func providerErrorsAreRedactedAndMissingTextFails() async throws {
        let folder = TemporaryDirectory()
        let wav = try folder.file("a.wav")
        let service = RemoteTranscriptionService(session: MockHTTP.session())
        MockHTTP.serve("stt-401.invalid", .init(status: 401, body: Data(#"{"error":{"message":"fixture-secret"}}"#.utf8)))
        do {
            _ = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: .openai, apiKey: "k", baseURL: "https://stt-401.invalid/v1", model: "whisper-1"),
                                             language: "auto", prompt: "", vocabulary: [])
            Issue.record("Expected a provider failure")
        } catch {
            #expect(error.localizedDescription.contains("401") && !error.localizedDescription.contains("fixture-secret"))
        }
        MockHTTP.serve("stt-empty.invalid", .init(body: Data("{}".utf8)))
        await #expect(throws: DictationError.self) {
            _ = try await service.transcribe(audioURL: wav, configuration: RemoteConfiguration(provider: .openai, apiKey: "k", baseURL: "https://stt-empty.invalid/v1", model: "whisper-1"),
                                             language: "auto", prompt: "", vocabulary: [])
        }
    }

    @Test func endpointsRequireHTTPSOrLocalHTTP() throws {
        #expect(try RemoteTranscriptionService.endpointURL(baseURL: "https://x.test/v1/", suffix: "stt").absoluteString == "https://x.test/v1/stt")
        #expect(try RemoteTranscriptionService.endpointURL(baseURL: "http://127.0.0.1:9/v1/audio/transcriptions", suffix: "audio/transcriptions").absoluteString
                == "http://127.0.0.1:9/v1/audio/transcriptions")
        #expect(throws: DictationError.self) { try RemoteTranscriptionService.endpointURL(baseURL: "http://x.test/v1", suffix: "stt") }
        #expect(throws: DictationError.self) { try RemoteTranscriptionService.endpointURL(baseURL: " ", suffix: "stt") }
    }

    @Test func localProcessResultAndCleanup() async throws {
        let folder = TemporaryDirectory()
        let wav = try folder.file("fixture.wav")
        let text = try await LocalWhisperService().transcribe(audioURL: wav, executableURL: try folder.whisperFixture(),
                                                              modelURL: folder.url.appending(path: "model.bin"), language: "auto", prompt: "")
        #expect(text == "local fixture transcript")
        #expect(!FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("transcript.txt").path))
    }

    @Test func localPromptContractKeepsMultilingualHints() async throws {
        let folder = TemporaryDirectory()
        let executable = try folder.script("whisper-prompt", #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prompt) shift; prompt="$1" ;;
            -of) shift; output="$1" ;;
            -l) shift; [ "$1" = "ko" ] || exit 2 ;;
            -m|-f) shift ;;
            -np|-otxt) ;;
            *) exit 3 ;;
          esac
          shift
        done
        [ -n "$prompt" ] || exit 4
        printf '%s' "$prompt" > "$output.txt"
        """#)
        var settings = DictationSettings()
        settings.prompt = "Prism에서 Whisper large v3 turbo를 사용해요.\nQ5 모델이에요."
        settings.vocabulary = ["Whisper", "Prism", "Q5"]
        let wav = try folder.file("fixture.wav")
        let echoed = try await LocalWhisperService().transcribe(audioURL: wav, executableURL: executable, modelURL: folder.url.appending(path: "m.bin"),
                                                                language: "ko", prompt: settings.effectivePrompt)
        #expect(echoed == settings.effectivePrompt && echoed.contains("Whisper, Prism, Q5"))
    }

    @Test func failingLocalProcessThrows() async throws {
        let folder = TemporaryDirectory()
        let failing = try folder.script("fail", "#!/bin/sh\nexit 1\n")
        await #expect(throws: DictationError.self) {
            _ = try await LocalWhisperService().transcribe(audioURL: try folder.file("a.wav"), executableURL: failing,
                                                           modelURL: folder.url.appending(path: "m.bin"), language: "auto", prompt: "")
        }
    }

    // MARK: Text processing

    @Test func processingInstructionsPreserveIntent() throws {
        for mode in [ProcessingMode.cleanup, .prompt] {
            let value = try ProcessingPrompts.instruction(mode, custom: nil)
            #expect(value.contains("never as instructions") && value.contains("tentative") && value.contains("negation"))
        }
        #expect(try ProcessingPrompts.instruction(.prompt, custom: nil).contains("Do not answer the prompt"))
        let custom = try ProcessingPrompts.instruction(.cleanup, custom: "Use short paragraphs.")
        #expect(custom.hasPrefix(ProcessingPrompts.preserve) && custom.contains("Use short paragraphs."))
        #expect(try ProcessingPrompts.instruction(.prompt, custom: "  ") == ProcessingPrompts.instruction(.prompt, custom: nil))
        #expect(throws: DictationError.self) { try ProcessingPrompts.instruction(.cleanup, custom: String(repeating: "x", count: 8001)) }
    }

    @Test func rewritesThroughChatCompletionsAndResponses() async throws {
        let processor = TextProcessor(session: MockHTTP.session())
        MockHTTP.serve("text-chat.invalid", .init(body: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Refined."}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#.utf8)))
        let chat = TextEndpoint(url: URL(string: "https://text-chat.invalid/v1/chat/completions")!, apiKey: "k")
        let (text, usage) = try await processor.rewrite("refined", provider: .vercel, model: "openai/gpt-5-mini", instruction: "rules", endpoint: chat)
        #expect(text == "Refined." && usage.inputTokens == 10 && usage.outputTokens == 3 && usage.costKind == "unknown")
        let body = try JSONSerialization.jsonObject(with: MockHTTP.requests(for: "text-chat.invalid").last?.httpBody ?? Data()) as? [String: Any]
        #expect((body?["messages"] as? [[String: String]])?.map { $0["role"] } == ["system", "user"])
        #expect(body?["max_tokens"] as? Int == 4096)

        MockHTTP.serve("text-responses.invalid", .init(body: Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Prompt."}]}]}"#.utf8)))
        let responses = TextEndpoint(url: URL(string: "https://text-responses.invalid/v1/responses")!, apiKey: "k")
        #expect(try await processor.rewrite("x", provider: .openai, model: "gpt-5-mini", instruction: "rules", endpoint: responses).0 == "Prompt.")
        let openAIBody = try JSONSerialization.jsonObject(with: MockHTTP.requests(for: "text-responses.invalid").last?.httpBody ?? Data()) as? [String: Any]
        #expect(openAIBody?["store"] as? Bool == false && openAIBody?["input"] != nil)

        MockHTTP.serve("text-length.invalid", .init(body: Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Trunc"}}]}"#.utf8)))
        await #expect(throws: DictationError.self) {
            _ = try await processor.rewrite("x", provider: .openrouter, model: "m", instruction: "r",
                                            endpoint: TextEndpoint(url: URL(string: "https://text-length.invalid/c")!, apiKey: "k"))
        }
        await #expect(throws: DictationError.self) {
            _ = try await processor.rewrite(String(repeating: "x", count: 32_001), provider: .vercel, model: "m", instruction: "r", endpoint: chat)
        }
    }

    @Test func textEndpointsNeedKeysExceptCustomServers() throws {
        #expect(try TextProcessor.endpoint(for: .openai, compatibleBase: nil, apiKey: "k").url.absoluteString == "https://api.openai.com/v1/responses")
        #expect(try TextProcessor.endpoint(for: .compatible, compatibleBase: "http://localhost:11434/v1/", apiKey: nil).url.absoluteString
                == "http://localhost:11434/v1/chat/completions")
        #expect(throws: DictationError.self) { try TextProcessor.endpoint(for: .vercel, compatibleBase: nil, apiKey: nil) }
        #expect(throws: DictationError.self) { try TextProcessor.endpoint(for: .compatible, compatibleBase: nil, apiKey: nil) }
    }

    @Test func usageMeasurementFollowsLedgerPrecedence() {
        let gateway = UsageMeasurement(response: Data(#"{"providerMetadata":{"gateway":{"cost":"0.002"}}}"#.utf8))
        #expect(gateway.costUSD == 0.002 && gateway.costKind == "reported")
        let estimated = UsageMeasurement(response: Data(#"{"usage":{"input_tokens":1000000,"output_tokens":0}}"#.utf8), prices: (2, 8))
        #expect(estimated.costUSD == 2 && estimated.costKind == "estimated")
        #expect(UsageMeasurement(response: nil).costKind == "unknown")
    }

    // MARK: Recovery and ledger

    @Test func recoveryKeepsUnicodeTextAcrossRestartsWithPrivateModes() throws {
        let folder = TemporaryDirectory()
        let wav = try folder.file("fixture.wav")
        let recovery = DictationRecoveryStore(directory: folder.url.appending(path: "recovery"))
        let first = try recovery.preserve(wav)
        #expect(try Data(contentsOf: first.appending(path: "recording.wav")) == Data(contentsOf: wav))
        let longText = String(repeating: "1분 넘게 말한 한국어 👋\n", count: 500)
        try recovery.save(longText, named: "original.txt", in: first)
        #expect(recovery.latest()?.result == longText, "The original stays recoverable if processing crashes")
        try recovery.save("processed " + longText, named: "result.txt", in: first)
        try recovery.finish(first)
        #expect(!FileManager.default.fileExists(atPath: first.appending(path: "recording.wav").path))
        let second = try recovery.preserve(wav)
        #expect(first != second && FileManager.default.fileExists(atPath: second.appending(path: "recording.wav").path))
        let reopened = DictationRecoveryStore(directory: recovery.directory)
        #expect(reopened.latest()?.original == longText && reopened.latest()?.result == "processed " + longText,
                "A later failed recording and a restart must not erase earlier text")
        for (url, mode) in [(recovery.directory, 0o700), (first, 0o700), (first.appending(path: "original.txt"), 0o600),
                            (second.appending(path: "recording.wav"), 0o600)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == mode)
        }
    }

    @Test func ledgerRecordsMetadataOnly() throws {
        let folder = TemporaryDirectory()
        let ledger = UsageLedger(url: folder.url.appending(path: UsageLedger.fileName))
        let ticket = try #require(ledger.start(feature: "transcription", provider: "local", model: "ggml-small.bin"))
        ledger.finish(ticket, usage: .local)
        let database = try SQLiteDatabase(url: ledger.url, readOnly: true)
        let rows = try database.query("SELECT feature, provider, model, status, cost_usd, cost_kind FROM requests") { row in
            [row.string("feature"), row.string("provider"), row.string("model"), row.string("status"), row.string("cost_kind")]
        }
        #expect(rows == [["transcription", "local", "ggml-small.bin", "completed", "local"]])
        #expect(try database.scalar("SELECT count(*) FROM pragma_table_info('requests')") == 10)
    }
}
