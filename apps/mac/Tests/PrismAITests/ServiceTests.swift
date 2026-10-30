import Foundation
import PrismKit
import Testing
@testable import PrismAI

/// Ported from `ai.rs` tool loop tests, plus mocked-transport checks of streaming, errors and usage.
struct ToolLoopTests {
    let messages = [Fixture.message("user", "Read my notes and find public documentation")]

    @Test func automaticSearchIsOfferedButADirectAnswerNeverSearches() async throws {
        for provider in [AIProvider.openai, .openrouter, .vercel] {
            var count = 0
            let answer = try await AIService.runTurn(provider: provider, model: "fixture", messages: messages, settings: AIToolSettings(),
                                                     current: { AIToolSettings() }) { _, model, body in
                count += 1
                #expect(model == "fixture" && body["tool_choice"] == "auto")
                if provider == .openai { #expect(body["tools"][0]["type"] == "web_search") } else { #expect(body["tools"][0]["function"]["name"] == "web_search") }
                return provider == .openai
                    ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Direct answer"]]]]]
                    : ["choices": [["finish_reason": "stop", "message": ["content": "Direct answer"]]]]
            }
            #expect(answer == "Direct answer" && count == 1)
        }
    }

    @Test func executesLocalAndSearchCallsThenReturnsAGroundedAnswer() async throws {
        let base = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = URL(filePath: AIFileIO.canonicalPath(base.path)!, directoryHint: .isDirectory)
        try Data("local fixture".utf8).write(to: root.appending(path: "notes.md"))
        var settings = AIToolSettings(localFiles: true, folders: [AIFolderGrant(id: "fixture", path: root.path)])
        settings.webSearch = true
        var step = 0
        let answer = try await AIService.runTurn(provider: .vercel, model: "zai/glm-5.3-flash", messages: messages, settings: settings,
                                                 current: { settings }) { _, model, body in
            defer { step += 1 }
            switch step {
            case 0:
                #expect(body["max_tokens"] == 16384 && body["tools"].array?.count == 3)
                return ["choices": [["finish_reason": "tool_calls", "message": [
                    "role": "assistant", "content": nil, "reasoning_content": "opaque provider state",
                    "tool_calls": [
                        ["id": "read1", "type": "function", "function": ["name": "read_local_file", "arguments": #"{"folder_id":"fixture","path":"notes.md"}"#]],
                        ["id": "search1", "type": "function", "function": ["name": "web_search", "arguments": #"{"query":"public documentation"}"#]],
                    ],
                ]]]]
            case 1:
                #expect(model == "perplexity/sonar" && !body.text.contains("local fixture"))
                return ["choices": [["finish_reason": "stop", "message": ["content": "Search summary"]]], "citations": ["https://example.com/docs"]]
            case 2:
                let stream = body["messages"].array ?? []
                #expect(stream[1]["reasoning_content"] == "opaque provider state")
                #expect(stream[2]["content"].string?.contains("local fixture") == true)
                #expect(stream[3]["content"].string?.contains("example.com") == true)
                return ["choices": [["finish_reason": "stop", "message": ["content": "Grounded answer"]]]]
            default:
                Issue.record("unexpected retry")
                return .null
            }
        }
        #expect(answer.contains("Grounded answer") && answer.contains("https://example.com/docs") && answer.contains("notes.md"))
        #expect(step == 3)
    }

    @Test func rejectsUnofferedToolsWithoutExecutingThem() async {
        await #expect(throws: AIError.self) {
            _ = try await AIService.runTurn(provider: .vercel, model: "fixture", messages: messages, settings: AIToolSettings(), current: { AIToolSettings() }) { _, _, _ in
                ["choices": [["message": ["tool_calls": [["id": "bad", "function": ["name": "run_shell", "arguments": "{}"]]]]]]]
            }
        }
    }

    @Test func revokedPermissionsStopBeforeAnotherProviderRequest() async {
        await #expect(throws: AIError.self) {
            _ = try await AIService.runTurn(provider: .vercel, model: "fixture", messages: messages, settings: AIToolSettings(localFiles: true),
                                            current: { AIToolSettings() }) { _, _, _ in
                Issue.record("permission must be checked first")
                return .null
            }
        }
    }

    @Test func openAIToolCallsUseResponsesItems() async throws {
        let base = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = URL(filePath: AIFileIO.canonicalPath(base.path)!, directoryHint: .isDirectory)
        try Data("fixture".utf8).write(to: root.appending(path: "a.txt"))
        let settings = AIToolSettings(localFiles: true, folders: [AIFolderGrant(id: "f", path: root.path)])
        var step = 0
        let answer = try await AIService.runTurn(provider: .openai, model: "gpt-5", messages: messages, settings: settings, current: { settings }) { _, _, body in
            defer { step += 1 }
            if step == 0 {
                #expect(body["tools"].array?.contains { $0["type"] == "function" && $0["name"] == "read_local_file" && $0["strict"] == false } == true)
                return ["status": "completed", "output": [["type": "function_call", "call_id": "c1", "name": "read_local_file", "arguments": #"{"folder_id":"f","path":"a.txt"}"#]]]
            }
            let input = body["input"].array ?? []
            #expect(input.last?["type"] == "function_call_output" && input.last?["call_id"] == "c1")
            return ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Done"]]]]]
        }
        #expect(answer.hasPrefix("Done") && answer.contains("a.txt"))
    }
}

/// A transport that replays canned responses and records requests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var chunks: [Data] }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? Reply(status: 500, chunks: []) : replies.removeFirst()
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        for chunk in reply.chunks { continuation.yield(chunk) }
        continuation.finish()
        return HTTPStreamResponse(status: reply.status, headers: reply.headers, body: body)
    }
}

struct ServiceTests {
    func service(_ transport: MockTransport, directory: URL) throws -> AIService {
        let service = AIService(paths: AppPaths(dataDirectory: directory), keys: AIKeyStore(service: "dev.prism.test.unused", compatibleService: "dev.prism.test.unused.c"),
                                transport: transport, cache: AIModelCache())
        _ = try service.compatible.save(baseUrl: "http://127.0.0.1:9/v1", key: nil, keys: service.keys)
        return service
    }

    @Test func streamsChatCompletionsWithThrottledUpdatesAndRecordsUsage() async throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"안\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"녕\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n"
        let bytes = Array(sse.utf8)
        // Split inside the multibyte character to exercise byte-level framing.
        let transport = MockTransport([.init(headers: ["Content-Type": "text/event-stream"], chunks: [Data(bytes[..<40]), Data(bytes[40...])])])
        let service = try service(transport, directory: directory)
        let updates = Updates()
        let answer = try await service.chat(provider: .compatible, model: "local/model", messages: [Fixture.message("user", "hi")], useFiles: false) { updates.append($0) }
        #expect(answer == "안녕")
        #expect(updates.values.last == "안녕")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:9/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSON.parse(request.httpBody ?? Data())
        #expect(body["stream"] == true && body["stream_options"]["include_usage"] == true && body["tools"].isNull)
        let summary = try #require(service.ledger).summary(since: 0)
        #expect(summary.month.requests == 1 && summary.month.inputTokens == 3 && summary.recent.first?.feature == "chat" && summary.recent.first?.status == "completed")
    }

    @Test func httpFailuresAreClassifiedAndLeaveUsageUnconfirmed() async throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport([.init(status: 429, headers: ["x-request-id": "req-9"], chunks: [Data(#"{"error":{"message":"slow down sk-secret"}}"#.utf8)])])
        let service = try service(transport, directory: directory)
        do {
            _ = try await service.chat(provider: .compatible, model: "local/model", messages: [Fixture.message("user", "hi")], useFiles: false) { _ in }
            Issue.record("expected failure")
        } catch let error as AIError {
            #expect(error.message.hasPrefix("Rate limit reached.") && error.message.contains("req-9") && !error.message.contains("sk-secret"))
        }
        #expect(try #require(service.ledger).summary(since: 0).recent.first?.status == "unconfirmed")
    }

    @Test func interruptedStreamsAreNeverSavedAsAnswers() async throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport([.init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)])])
        let service = try service(transport, directory: directory)
        await #expect(throws: AIError.self) {
            _ = try await service.chat(provider: .compatible, model: "local/model", messages: [Fixture.message("user", "hi")], useFiles: false) { _ in }
        }
    }

    @Test func catalogsAreParsedAndCached() async throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = #"{"data":[{"id":"creator/chat","name":"Chat","type":"language","modalities":{"input":["text"],"output":["text"]},"context_window":64000,"max_tokens":8000,"pricing":{"input":"0.000001","output":"0.000002"}}]}"#
        let transport = MockTransport([.init(chunks: [Data(catalog.utf8)])])
        let service = try service(transport, directory: directory)
        let models = try await service.listModels(.vercel)
        #expect(models.map(\.id) == ["creator/chat"])
        #expect(transport.requests.first?.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/models")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        let budget = await service.contextBudget(.vercel, model: "creator/chat", requestedOutput: 16_384)
        #expect(budget.output == 8000)
        #expect(await service.cache.prices("creator/chat", provider: .vercel).map { abs($0.0 - 1) < 1e-9 } == true)
    }

    @Test func openAICatalogNeedsAKeyAlreadyOpenedInThisProcess() async throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try service(MockTransport([]), directory: directory)
        await #expect(throws: AIError.self) { _ = try await service.listModels(.openai) }
    }
}

final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
