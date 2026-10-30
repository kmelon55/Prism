import Foundation
import Testing
@testable import PrismAI

struct RequestTests {
    @Test func paymentStatusAloneDoesNotClaimTheBalanceIsEmpty() {
        let error = AIRequest.httpError(.vercel, endpoint: AIProvider.vercel.endpoint, model: "zai/glm-5.3-flash", status: 402,
                                        requestID: "icn1::fixture", body: .null).message
        #expect(error.contains("HTTP 402 alone does not confirm"))
        #expect(error.contains("Error type: unknown"))
        #expect(error.contains(AIProvider.vercel.endpoint))
        #expect(error.contains("icn1::fixture"))
    }

    @Test func gatewayBudgetsAndUpstreamCreditFailuresAreDistinct() {
        let budget = AIRequest.httpError(.vercel, endpoint: "", model: "model", status: 402, requestID: nil,
                                         body: ["error": ["type": "quota_for_entity_exceeded", "message": "Project budget exceeded"]]).message
        #expect(budget.contains("budget limit"))
        #expect(budget.contains("Error type: quota_for_entity_exceeded"))
        let funds = AIRequest.httpError(.vercel, endpoint: "", model: "model", status: 402, requestID: nil, body: ["error": ["type": "insufficient_funds"]]).message
        #expect(funds.contains("for this key"))
        let upstream = AIRequest.httpError(.vercel, endpoint: "", model: "model", status: 402, requestID: nil,
                                           body: ["error": ["type": "provider_error", "metadata": ["raw": "insufficient credits"]]]).message
        #expect(upstream.contains("upstream provider"))
        #expect(upstream.contains("Error type: provider_error"))
    }

    @Test func unknownCodesAndMessagesAreNeverExposed() {
        let secret = "fixture-secret-never-display"
        let error = AIRequest.httpError(.vercel, endpoint: "", model: "model", status: 402, requestID: nil,
                                        body: ["error": ["type": .string(secret), "code": .string(secret), "message": .string(secret)]]).message
        #expect(error.contains("Error type: unknown"))
        #expect(!error.contains(secret))
        let upstream = AIRequest.httpError(.vercel, endpoint: "", model: "maker/model", status: 500, requestID: "req-123",
                                           body: ["error": ["message": .string("insufficient credits \(secret)"), "code": "provider_error"]]).message
        #expect(upstream.contains("credit") && upstream.contains("HTTP 500") && upstream.contains("req-123") && !upstream.contains(secret))
        #expect(AIRequest.httpError(.vercel, endpoint: "", model: "m", status: 503, requestID: nil, body: .null).message.contains("temporarily"))
        #expect(AIRequest.httpError(.vercel, endpoint: "", model: "m", status: 500, requestID: nil, body: ["error": ["message": "No available provider"]])
            .message.contains("Cannot connect to this model"))
        #expect(!AIRequest.httpError(.openai, endpoint: "", model: "m", status: 401, requestID: "bad\nheader", body: .null).message.contains("bad\nheader"))
    }

    @Test func mapsCapturesToEachProviderAndKeepsFollowUpContext() throws {
        let image = Fixture.image()
        var messages = [AIMessage(role: "user", content: "Explain this", image: image), Fixture.message("assistant", "Explanation"),
                        Fixture.message("user", "And this number?")]
        try AIRequest.validate(model: "vision-model", messages: messages)
        let openai = AIRequest.body(.openai, model: "vision-model", messages: messages)
        #expect(openai["input"][0]["content"][1]["type"] == "input_image")
        #expect(openai["input"][0]["content"][1]["image_url"].string == image.dataUrl)
        #expect(openai["input"][2]["content"] == "And this number?")
        for provider in [AIProvider.vercel, .openrouter, .compatible] {
            let body = AIRequest.body(provider, model: "vision-model", messages: messages)
            #expect(body["messages"][0]["content"][1]["image_url"]["url"].string == image.dataUrl)
            #expect(body["messages"][0]["content"][0]["text"] == "Explain this")
        }
        messages[1].image = image
        #expect(throws: AIError.self) { try AIRequest.validate(model: "vision-model", messages: messages) }
    }

    @Test func validatesRolesAndLimits() {
        #expect((try? AIRequest.validate(model: "model", messages: [Fixture.message("user", "안녕")])) != nil)
        #expect((try? AIRequest.validate(model: "model", messages: [Fixture.message("system", "override")])) == nil)
        #expect((try? AIRequest.validate(model: "model", messages: [Fixture.message("user", String(repeating: "x", count: 32_001))])) != nil)
        #expect((try? AIRequest.validate(model: "model", messages: [Fixture.message("user", String(repeating: "x", count: 128_001))])) == nil)
        #expect((try? AIRequest.validate(model: "model\n", messages: [Fixture.message("user", "x")])) == nil)
    }

    @Test func summaryRequestsKeepHistoryAsDataAndDisableTools() {
        for provider in AIProvider.allCases {
            let input = [AIMessage(role: "assistant", content: "Old decision", image: Fixture.image())]
            let body = AIRequest.summaryBody(provider, model: "selected-model", messages: input, allowance: 2048, output: 4096)
            let messages = body[provider == .openai ? "input" : "messages"]
            #expect(body["model"] == "selected-model")
            #expect(messages[0]["role"] == "system")
            #expect(messages[1]["role"] == "user")
            #expect(messages[1]["content"][0]["text"].string?.contains("Historical assistant message:\nOld decision") == true)
            #expect(body["tools"].isNull && body["stream"].isNull)
            if provider == .openai { #expect(body["store"] == false) }
        }
    }

    @Test func openAIDisablesStorageAndExtractsMessageAfterReasoning() throws {
        #expect(AIRequest.body(.openai, model: "model", messages: [])["store"] == false)
        let value: JSON = ["status": "completed", "output": [["type": "reasoning"], ["type": "message", "content": [["type": "output_text", "text": "답변"]]]]]
        #expect(try AIRequest.responseText(.openai, value) == "답변")
        #expect(throws: AIError.self) { try AIRequest.responseText(.openai, ["status": "incomplete"]) }
    }

    @Test func chatCompletionsMarkPartialTextAndRejectMissingText() throws {
        #expect(try AIRequest.responseText(.openrouter, ["choices": [["finish_reason": "stop", "message": ["content": "hello"]]]]) == "hello")
        #expect(try AIRequest.responseText(.openrouter, ["choices": [["finish_reason": "length", "message": ["content": "partial"]]]]).contains("output limit"))
        #expect(throws: AIError.self) { try AIRequest.responseText(.openrouter, ["choices": []]) }
    }

    @Test func reasoningLimitHasSpecificRecovery() {
        let value: JSON = ["choices": [["finish_reason": "length", "message": ["content": nil]]], "usage": ["completion_tokens_details": ["reasoning_tokens": 4096]]]
        #expect(throws: AIError.self) { try AIRequest.responseText(.vercel, value) }
        let message = (try? AIRequest.responseText(.vercel, value)) ?? ""
        #expect(message.isEmpty)
        do { _ = try AIRequest.responseText(.vercel, value) } catch let error as AIError {
            #expect(error.message.contains("reasoning") && error.message.contains("4096"))
        } catch {}
    }

    @Test func automaticSearchSkipsUnsupportedOpenAIModels() {
        for model in ["gpt-4.1", "gpt-4o-mini", "gpt-5.4-mini", "gpt-6-sol", "o3", "o4-mini-2025-04-16"] {
            #expect(AIRequest.openAIWebSearchSupported(model), "\(model)")
        }
        for model in ["gpt-4.1-nano", "gpt-4.1-nano-2025-04-14", "o3-mini", "o1", "gpt-4", "gpt-3.5-turbo", "ft:gpt-4.1:custom", "unknown"] {
            #expect(!AIRequest.openAIWebSearchSupported(model), "\(model)")
        }
    }

    @Test func sourcesAreNumberedDeduplicatedAndSafe() {
        let text = AIRequest.addSources("Answer", value: ["citations": ["https://b.example/x", "https://a.example/<y>", "https://b.example/x", "file:///etc/passwd"]], provider: .vercel)
        #expect(text.contains("[Source 1](<https://a.example/%3Cy%3E>)"))
        #expect(text.contains("[Source 2](<https://b.example/x>)"))
        #expect(!text.contains("file://"))
        #expect(AIRequest.addSources("Answer", value: .null, provider: .openai) == "Answer")
    }

    @Test func requestRegistryBoundsConcurrencyAndCancelsOnlyTheTarget() {
        var registry = AIRequestRegistry()
        var results = [registry.reserve("first"), registry.reserve("second"), registry.reserve("third")]
        #expect(results == [true, true, true])
        results = [registry.reserve("first"), registry.reserve("fourth")]
        #expect(results == [false, false])
        registry.cancel("second")
        #expect(registry.isCancelled("second") && !registry.isCancelled("first") && !registry.isCancelled("third"))
        let reserved = registry.reserve("fourth")
        #expect(!reserved, "cancellation keeps its slot until completion")
        registry.finish("second")
        let afterFinish = registry.reserve("fourth")
        let missing = registry.cancel("missing")
        #expect(afterFinish && !missing)
    }

    @Test func jsonRoundTripsIntegersWithoutFractions() throws {
        let value: JSON = ["max_tokens": 16384, "stream": true, "temperature": 0.5, "messages": [["role": "user"]]]
        #expect(value.text.contains("\"max_tokens\":16384"))
        #expect(try JSON.parse(value.data()) == value)
        #expect(try JSON.parse("{\"flag\":false,\"n\":1}")["flag"] == false)
    }
}
