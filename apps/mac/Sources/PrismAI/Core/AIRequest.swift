import Foundation

/// Request bodies, response extraction and error classification for each provider wire format.
/// OpenAI uses Responses with `store: false`; every other connection uses Chat Completions.
enum AIRequest {
    static let maxConversationBytes = 128_000

    static func isASCIIGraphic(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    static func isValidModelID(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 200 && isASCIIGraphic(model)
    }

    static func validate(model: String, messages: [AIMessage]) throws {
        guard isValidModelID(model) else { throw AIError(L("Enter a valid model ID.")) }
        let invalid = messages.isEmpty
            || messages.last?.role != "user"
            || messages.enumerated().contains { index, message in
                message.role != (index % 2 == 0 ? "user" : "assistant")
                    || message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || message.content.utf8.count > AIContext.maxMessageBytes
            }
            || messages.reduce(0, { $0 + $1.content.utf8.count }) > maxConversationBytes
        if invalid { throw AIError(L("The conversation is invalid or too long. Start a new one or shorten it.")) }
        let images = messages.compactMap(\.image)
        if images.count > ChatImageCodec.maxSessionImages || messages.contains(where: { $0.role != "user" && $0.image != nil }) {
            throw AIError(L("Each conversation can use up to four images."))
        }
        for image in images { try ChatImageCodec.validate(image) }
    }

    static func messagesJSON(_ provider: AIProvider, _ messages: [AIMessage]) -> [JSON] {
        messages.map { message in
            guard let image = message.image else { return ["role": .string(message.role), "content": .string(message.content)] }
            let content: JSON = provider == .openai
                ? [["type": "input_text", "text": .string(message.content)], ["type": "input_image", "image_url": .string(image.dataUrl)]]
                : [["type": "text", "text": .string(message.content)], ["type": "image_url", "image_url": ["url": .string(image.dataUrl)]]]
            return ["role": .string(message.role), "content": content]
        }
    }

    static func body(_ provider: AIProvider, model: String, messages: [AIMessage]) -> JSON {
        let input = JSON.array(messagesJSON(provider, messages))
        return provider == .openai
            ? ["model": .string(model), "input": input, "store": false, "max_output_tokens": 4096]
            : ["model": .string(model), "messages": input, "max_tokens": 4096]
    }

    static func outputLimitKey(_ provider: AIProvider) -> String {
        provider == .openai ? "max_output_tokens" : "max_tokens"
    }

    static func responseText(_ provider: AIProvider, _ value: JSON) throws -> String {
        let incomplete = AIError(L("The response is incomplete. Shorten the request or try another model."))
        let text: String
        if provider == .openai {
            guard value["status"] == "completed" else { throw incomplete }
            text = (value["output"].array ?? [])
                .filter { $0["type"] == "message" }
                .flatMap { $0["content"].array ?? [] }
                .filter { $0["type"] == "output_text" }
                .compactMap { $0["text"].string }
                .joined(separator: "\n")
        } else {
            let choice = value["choices"][0]
            if choice["finish_reason"] == "length" {
                let content = choice["message"]["content"].string ?? ""
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return content + "\n\n— " + L("The answer stopped at the output limit. You can raise the limit in settings.")
                }
                let reasoning = value["usage"]["completion_tokens_details"]["reasoning_tokens"].uint ?? 0
                throw AIError(L("The output limit was reached while reasoning, so no answer was produced. Raise the output limit in AI settings.") + "\n"
                    + L("Finish reason: length · Reasoning tokens: \(String(reasoning))"))
            }
            guard choice["finish_reason"] == "stop" else { throw incomplete }
            text = choice["message"]["content"].string ?? ""
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIError(L("No text response was received. Check that this is a text model."))
        }
        return text
    }

    private static let recognizedErrorTypes: Set<String> = [
        "quota_for_entity_exceeded", "insufficient_funds", "insufficient_quota", "provider_error", "invalid_api_key",
        "authentication_error", "model_not_found", "rate_limit_exceeded", "access_denied", "invalid_request_error",
        "internal_server_error",
    ]

    /// Classifies bounded provider metadata. Raw provider messages and unknown codes never leave this function,
    /// because they may echo credentials or conversation text.
    static func httpError(_ provider: AIProvider, endpoint: String, model: String, status: Int, requestID: String?, body: JSON) -> AIError {
        let error = body["error"]
        let details = [error["code"].string, error["type"].string, error["message"].string, error["metadata"]["raw"].string]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let errorType = [error["type"].string, error["code"].string].compactMap { $0 }.first { recognizedErrorTypes.contains($0) }
        let upstream = details.contains("provider_error") || error["metadata"]["raw"].string != nil
        let contains = { (words: [String]) in words.contains { details.contains($0) } }
        let message: String
        if !upstream && details.contains("quota_for_entity_exceeded") {
            message = L("Gateway reported a budget limit for this key. Check team, project and key budgets.")
        } else if contains(["insufficient_quota", "insufficient_funds", "insufficient funds", "insufficient credits", "credit balance"]) {
            message = upstream
                ? L("The upstream provider reported a credit or quota error. This does not establish a Gateway balance shortage.")
                : L("The server reported insufficient credit or quota for this key. Check the key's account, team and billing settings.")
        } else if status == 402 {
            message = L("The server rejected billing or quota validation. HTTP 402 alone does not confirm insufficient balance.")
        } else if status == 401 {
            message = L("API key rejected. Change it in settings.")
        } else if status == 403 {
            message = L("You cannot access this model. Check account permissions and billing.")
        } else if status == 429 {
            message = L("Rate limit reached. Try again shortly.")
        } else if contains(["context_length", "context window", "too many tokens"]) {
            message = L("The conversation exceeds this model's context limit. Start a new conversation.")
        } else if status == 404 || contains(["model_not_found", "no available provider", "no endpoints found", "model is not available", "model not found"]) {
            message = L("Cannot connect to this model right now. Choose another in settings and start a new conversation.")
        } else if status == 400 || status == 422 || details.contains("unsupported_parameter") {
            message = L("The model rejected the request format. Start a chat with another model or check error details.")
        } else if status == 408 || status == 504 {
            message = L("The model server timed out. Retry or use another model.")
        } else if [502, 503, 529].contains(status) {
            message = L("The model server is temporarily unavailable. Retry later or start a new chat with another model.")
        } else {
            message = L("The provider failed to process the request. Retry or start a new conversation with another model.")
        }
        var text = "\(message)\n\(provider.diagnosticName) · \(model) · HTTP \(status)"
        text += "\n" + L("Request URL: \(endpoint)")
        text += "\n" + L("Error type: \(errorType ?? "unknown")")
        if let requestID, requestID.utf8.count <= 160,
           requestID.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || "-_:./".utf8.contains($0) }) {
            text += "\n" + L("Request ID: \(requestID)")
        }
        return AIError(text)
    }

    /// Appends web citations as numbered Markdown links.
    static func addSources(_ text: String, value: JSON, provider: AIProvider) -> String {
        var urls = (value["citations"].array ?? []).compactMap(\.string)
        let annotations: [JSON] = provider == .openai
            ? (value["output"].array ?? []).flatMap { $0["content"].array ?? [] }.flatMap { $0["annotations"].array ?? [] }
            : value["choices"][0]["message"]["annotations"].array ?? []
        for item in annotations {
            if let url = item["url_citation"]["url"].string ?? item["url"].string { urls.append(url) }
        }
        urls = Array(Set(urls.filter { url in
            url.utf8.count < 2048 && URL(string: url).flatMap(\.scheme).map { ["http", "https"].contains($0.lowercased()) } == true
        })).sorted()
        guard !urls.isEmpty else { return text }
        var result = text + "\n\n" + L("Web sources") + "\n"
        for (index, url) in urls.prefix(8).enumerated() {
            let escaped = url.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C")
                .replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\r", with: "%0D")
            result += "\n- [" + L("Source \(index + 1)") + "](<\(escaped)>)"
        }
        return result
    }

    /// OpenAI's catalog omits hosted-tool capabilities. Unsupported legacy and fine-tuned models keep plain chat.
    static func openAIWebSearchSupported(_ model: String) -> Bool {
        if model.hasPrefix("gpt-4.1-nano") || model.hasPrefix("o3-mini") { return false }
        return ["gpt-4.1", "gpt-4o", "gpt-5", "gpt-6", "o3", "o4-mini"].contains { family in
            model == family || (model.hasPrefix(family) && ["-", "."].contains(model.dropFirst(family.count).first.map(String.init) ?? ""))
        }
    }

    static func summaryBody(_ provider: AIProvider, model: String, messages: [AIMessage], allowance: Int, output: Int) -> JSON {
        var input = [AIMessage(role: "system", content: "\(AIContext.summaryInstruction) Aim for at most \(allowance / 3) tokens of summary text.")]
        input += messages.map { AIMessage(role: "user", content: "Historical \($0.role) message:\n\($0.content)", image: $0.image) }
        var body = body(provider, model: model, messages: input)
        body[outputLimitKey(provider)] = JSON(output)
        return body
    }
}
