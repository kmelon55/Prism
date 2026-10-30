import Foundation
import Testing
@testable import PrismAI

struct StreamTests {
    @Test func parsesUTF8AndCRLFAtEveryByteBoundary() throws {
        let input = Array("data: {\"text\":\"안녕\"}\r\n\r\n: keepalive\n\ndata: [DONE]\n\n".utf8)
        for split in 0..<input.count {
            var parser = SSEParser()
            var events = try parser.push(input[..<split])
            events += try parser.push(input[split...])
            #expect(events == ["{\"text\":\"안녕\"}", "[DONE]"])
        }
    }

    @Test func multiLineDataJoinsWithNewlines() throws {
        var parser = SSEParser()
        #expect(try parser.push("data: one\ndata: two\n\n".utf8) == ["one\ntwo"])
        #expect(try parser.push("data: tail".utf8).isEmpty)
        #expect(try parser.finish() == ["tail"])
    }

    @Test func finalUsageChunkSurvivesAfterContentFinishes() throws {
        var stream = StreamAccumulator(provider: .openrouter)
        _ = try stream.event(#"{"choices":[{"delta":{"content":"hello"},"finish_reason":"stop"}]}"#)
        _ = try stream.event(#"{"choices":[],"usage":{"prompt_tokens":25,"completion_tokens":5,"cost":0.00003}}"#)
        _ = try stream.event("[DONE]")
        let usage = UsageMeasurement.measure(try stream.finish(), prices: nil)
        #expect(usage.inputTokens == 25 && usage.outputTokens == 5 && usage.costUSD == 0.00003)
    }

    @Test func rebuildsTextAndSplitToolArguments() throws {
        var stream = StreamAccumulator(provider: .vercel)
        _ = try stream.event(#"{"choices":[{"delta":{"content":"안녕","tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"id\":"}}]}}]}"#)
        _ = try stream.event(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"one\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        let value = try stream.finish()
        #expect(value["choices"][0]["message"]["content"] == "안녕")
        #expect(value["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] == "{\"id\":\"one\"}")
        #expect(value["choices"][0]["message"]["tool_calls"][0]["id"] == "call_1")
    }

    @Test func mergesReasoningDeltasWithoutChangingEncryptedBlocks() throws {
        var stream = StreamAccumulator(provider: .openrouter)
        let details: [JSON] = [
            ["type": "reasoning.text", "index": 0, "text": "Think ", "signature": nil],
            ["type": "reasoning.text", "index": 0, "text": "carefully", "signature": "signed"],
            ["type": "reasoning.summary", "index": 1, "summary": "First "],
            ["type": "reasoning.summary", "index": 1, "summary": "step"],
            ["type": "reasoning.encrypted", "index": 2, "data": "opaque"],
            ["type": "reasoning.encrypted", "index": 3, "data": "second"],
        ]
        for detail in details {
            _ = try stream.event(JSON.object(["choices": [["delta": ["reasoning_details": [detail]]]]]).text)
        }
        _ = try stream.event(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        let merged = try stream.finish()["choices"][0]["message"]["reasoning_details"].array ?? []
        #expect(merged.count == 4)
        #expect(merged[0]["text"] == "Think carefully" && merged[0]["signature"] == "signed")
        #expect(merged[1]["summary"] == "First step")
        #expect(merged[2]["data"] == "opaque" && merged[3]["data"] == "second")
    }

    @Test func requiresTerminalResponseAndKeepsOpenAICompletedPayload() throws {
        var partial = StreamAccumulator(provider: .openai)
        #expect(try partial.event(#"{"type":"response.output_text.delta","delta":"hello"}"#))
        #expect(throws: AIError.self) { try partial.finish() }
        var complete = StreamAccumulator(provider: .openai)
        _ = try complete.event(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        #expect(try complete.finish()["status"] == "completed")
    }

    @Test func streamErrorsStopTheAnswer() {
        var stream = StreamAccumulator(provider: .vercel)
        #expect(throws: AIError.self) { _ = try stream.event(#"{"error":{"message":"boom"}}"#) }
        #expect(throws: AIError.self) { _ = try stream.event("not json") }
    }
}

struct CatalogTests {
    @Test func compatibleModelsUseChatCompletionsWithoutGuessingPrices() throws {
        let rows = try AIModelCatalog.parse(.compatible, ["data": [["id": "local/llama-fixture", "pricing": ["input": 10, "output": 20]], ["id": "local/llama-fixture"], ["id": ""]]])
        #expect(rows.count == 1 && rows[0].id == "local/llama-fixture" && rows[0].inputPrice == nil && rows[0].outputPrice == nil)
        let body = AIRequest.body(.compatible, model: "local/llama-fixture", messages: [Fixture.message("user", "hello")])
        #expect(body["messages"][0]["content"] == "hello" && body["input"].isNull)
    }

    @Test func vercelUsesGatewayAccountAndChatContract() throws {
        #expect(AIProvider.vercel.account == "vercel")
        #expect(AIProvider.vercel.endpoint == "https://ai-gateway.vercel.sh/v1/chat/completions")
        let body = AIRequest.body(.vercel, model: "creator/model", messages: [Fixture.message("user", "hello")])
        #expect(body["model"] == "creator/model" && body["messages"][0]["content"] == "hello")
    }

    @Test func gatewayCatalogExcludesNonLanguageAndNonTextModels() throws {
        let models = try AIModelCatalog.parse(.vercel, ["data": [
            ["id": "creator/chat", "name": "Chat", "type": "language", "modalities": ["input": ["text", "image"], "output": ["text"]], "context_window": 128000],
            ["id": "creator/embed", "type": "embedding", "modalities": ["input": ["text"], "output": ["text"]]],
            ["id": "creator/speech", "type": "language", "modalities": ["input": ["audio"], "output": ["audio"]]],
        ]])
        #expect(models.map(\.id) == ["creator/chat"])
        #expect(models[0].contextWindow == 128_000 && models[0].supportsImages == true)
    }

    @Test func openRouterFiltersBatchAndDeduplicates() throws {
        let row: JSON = ["id": "creator/chat", "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]]]
        var batch = row
        batch["id"] = "creator/chat:batch"
        let models = try AIModelCatalog.parse(.openrouter, ["data": [row, row, batch]])
        #expect(models.count == 1 && models[0].name == "creator/chat")
        #expect(throws: AIError.self) { try AIModelCatalog.parse(.openrouter, ["error": "failed"]) }
    }

    @Test func openAIFiltersSpecializedModels() {
        for id in ["gpt-future-mini", "o3", "ft:gpt-4.1-mini:org:custom"] { #expect(AIModelCatalog.openAITextCandidate(id), "\(id)") }
        for id in ["gpt-image-1", "gpt-4o-realtime-preview", "gpt-4o-mini-tts", "text-embedding-3-small", "gpt-4o-search-preview"] {
            #expect(!AIModelCatalog.openAITextCandidate(id), "\(id)")
        }
    }

    @Test func pricesUseMillionTokensAndPreserveZeroOrUnavailable() throws {
        #expect(AIModelCatalog.millionTokenPrice("0.00000012").map { abs($0 - 0.12) < 1e-9 } == true)
        #expect(AIModelCatalog.millionTokenPrice(0) == 0)
        for value: JSON in [nil, "-1", "NaN", "1e999"] { #expect(AIModelCatalog.millionTokenPrice(value) == nil) }
        let router = try AIModelCatalog.parse(.openrouter, ["data": [[
            "id": "creator/chat", "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]],
            "pricing": ["prompt": "0.000003", "completion": "0.000015", "overrides": [["min_prompt_tokens": 200000]]],
        ]]])
        #expect(abs((router[0].inputPrice ?? 0) - 3) < 1e-8 && abs((router[0].outputPrice ?? 0) - 15) < 1e-8 && router[0].pricingVariable)
        #expect(AIPrice.format(nil) == "Not provided" && AIPrice.format(0) == "$0" && AIPrice.format(0.00001) == "<$0.0001" && AIPrice.format(1234.5) == "$1,234.5")
        #expect([nil, 0, 0.05, 0.3, 1, 5, 20].map(AIPrice.level) == [nil, 0, 1, 2, 3, 4, 5])
    }

    @Test func textOnlyModelsKeepPlainChatAndRejectImagesOrFileTools() throws {
        let rows = try AIModelCatalog.parse(.openrouter, ["data": [["id": "plain", "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]], "supported_parameters": []]]])
        var settings = AIToolSettings()
        try AIModelCatalog.apply(rows[0], to: &settings, messages: [Fixture.message("user", "hi")])
        #expect(!settings.webSearch)
        settings.localFiles = true
        #expect(throws: AIError.self) { try AIModelCatalog.apply(rows[0], to: &settings, messages: [Fixture.message("user", "hi")]) }
        var plain = AIToolSettings()
        #expect(throws: AIError.self) { try AIModelCatalog.apply(rows[0], to: &plain, messages: [AIMessage(role: "user", content: "hi", image: Fixture.image())]) }
    }
}

struct ModelSearchTests {
    let models = [("GPT-4o Mini", "openai/gpt-4o-mini", ""), ("Claude Sonnet 4.5", "anthropic/claude-sonnet-4.5", ""), ("Whisper Large v3", "whisper-large-v3", "OpenAI")]

    func filter(_ query: String) -> [String] {
        let search = ModelSearch(query)
        return models.filter { search.matches(name: $0.0, id: $0.1, ownedBy: $0.2) }.map(\.1)
    }

    @Test(arguments: ["gpt 4o", "  GPT   4o  mini  ", "gpt4omini", "g p t 4o", "GPT_4o/Mini", "ＧＰＴ　４ｏ", "gpt–4o", "mini openai", "4o\tmini"])
    func findsTheSameModel(_ query: String) {
        #expect(filter(query) == ["openai/gpt-4o-mini"])
    }

    @Test func matchesReorderedWordsAcrossNamesIDsAndOwners() {
        #expect(filter("4.5 anthropic sonnet") == ["anthropic/claude-sonnet-4.5"])
        #expect(filter("openai large whisper") == ["whisper-large-v3"])
    }

    @Test(arguments: ["", "   ", "\t\n\u{00a0}\u{3000}"])
    func blankQueryShowsAll(_ query: String) {
        #expect(filter(query).count == 3)
    }

    @Test func requiresEveryTermAndPreservesVersions() {
        #expect(filter("gpt unknown").isEmpty)
        #expect(filter("sonnet 45").isEmpty)
        #expect(filter("sonnet 4.6").isEmpty)
    }

    @Test func sortsByPriceWithMissingPricesLast() {
        let rows = [AIModel(id: "b", name: "B", inputPrice: 2), AIModel(id: "a", name: "A"), AIModel(id: "c", name: "C", inputPrice: 1)]
        #expect(ModelSort.input.sorted(rows).map(\.id) == ["c", "b", "a"])
        #expect(ModelSort.name.sorted(rows).map(\.id) == ["a", "b", "c"])
    }
}
