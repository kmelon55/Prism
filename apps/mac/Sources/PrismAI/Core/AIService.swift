import Foundation
import PrismKit

/// Native provider access: keys, catalogs, context preparation, streaming inference and the bounded tool loop.
/// Endpoints are fixed per provider (or the one saved custom server), redirects are refused, and keys are read here
/// rather than passed around the UI.
final class AIService: Sendable {
    let keys: AIKeyStore
    let selection: AISelectionStore
    let compatible: CompatibleStore
    let tools: AIToolStore
    let ledger: UsageLedger?
    let transport: any HTTPTransport
    let cache: AIModelCache

    static let maxBody = 1_048_576

    init(paths: AppPaths, keys: AIKeyStore = AIKeyStore(), transport: any HTTPTransport = URLSessionTransport(), cache: AIModelCache = .shared) {
        self.keys = keys
        selection = AISelectionStore(url: paths.file("ai-selection-v1.json"))
        compatible = CompatibleStore(url: paths.file("ai-compatible-v1.json"))
        tools = AIToolStore(url: paths.file("ai-tools-v1.json"))
        ledger = try? UsageLedger(url: paths.file("ai-usage-v1.sqlite"))
        self.transport = transport
        self.cache = cache
    }

    // MARK: Keys

    func keyConfigured(_ provider: AIProvider) throws -> Bool {
        if provider == .compatible { return !(try compatible.load().baseUrl.isEmpty) }
        return try keys.info(provider).configured
    }

    /// The URL and authorization for the saved custom server. `allowPrompt` is only set by explicit actions.
    func compatibleTarget(_ suffix: String, allowPrompt: Bool) throws -> (URL, String?) {
        let connection = try compatible.load()
        let base = try CompatibleConnection.normalize(connection.baseUrl)
        var authorization: String?
        if connection.hasKey {
            guard let key = try keys.compatibleKey(base: base, allowPrompt: allowPrompt) else {
                throw AIError(L("The saved custom API key is unavailable. Save it again in AI settings."))
            }
            authorization = "Bearer " + String(decoding: key, as: UTF8.self)
        }
        guard let url = URL(string: base + suffix) else { throw AIError(L("Enter a valid API base URL.")) }
        return (url, authorization)
    }

    // MARK: Catalogs

    func listModels(_ provider: AIProvider) async throws -> [AIModel] {
        if provider == .compatible { return try await listCompatibleModels() }
        guard let endpoint = provider.catalogEndpoint.flatMap(URL.init(string:)) else { throw AIError(L("Invalid request.")) }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        if provider == .openai {
            request.setValue("Bearer " + String(decoding: try keys.cachedKey(for: provider), as: UTF8.self), forHTTPHeaderField: "Authorization")
        }
        let transport = transport, catalogRequest = request
        let response: HTTPStreamResponse
        do {
            response = try await withDeadline(20, error: AIError(L("Could not fetch models. Check your connection and try again."))) {
                try await transport.send(catalogRequest)
            }
        } catch let error as AIError { throw error } catch is CancellationError { throw CancellationError() } catch {
            throw AIError(L("Could not fetch models. Check your connection and try again."))
        }
        guard (200..<300).contains(response.status) else {
            let message = switch response.status {
            case 401, 403: L("Cannot access the model catalog. Check your API key and account permissions.")
            case 429: L("Too many model catalog requests. Try again shortly.")
            default: L("Could not fetch models from the provider. Try again.")
            }
            throw AIError(message)
        }
        let data = try await response.collect(limit: 8 * Self.maxBody, tooLarge: AIError(L("The model catalog is too large.")),
                                              failure: AIError(L("Could not read the model catalog.")))
        guard let value = try? JSON.parse(data) else { throw AIError(L("Invalid model catalog format.")) }
        let models = try AIModelCatalog.parse(provider, value)
        await cache.store(models, for: provider)
        return models
    }

    private func listCompatibleModels() async throws -> [AIModel] {
        let (base, authorization) = try compatibleTarget("models", allowPrompt: false)
        var request = URLRequest(url: base, timeoutInterval: 15)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let transport = transport, catalogRequest = request
        let response: HTTPStreamResponse
        do {
            response = try await withDeadline(15, error: AIError(L("Could not load models. Check the server or enter a model ID manually."))) {
                try await transport.send(catalogRequest)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            throw AIError(L("Could not load models. Check the server or enter a model ID manually."))
        }
        guard (200..<300).contains(response.status) else {
            throw AIError(L("Model lookup failed (HTTP \(response.status)). Enter a model ID manually if this server has no model catalog."))
        }
        let data = try await response.collect(limit: Self.maxBody, tooLarge: AIError(L("The model catalog is too large.")),
                                              failure: AIError(L("Could not read the model catalog.")))
        guard let value = try? JSON.parse(data) else { throw AIError(L("The model catalog is malformed.")) }
        return try AIModelCatalog.parse(.compatible, value)
    }

    func contextBudget(_ provider: AIProvider, model: String, requestedOutput: Int) async -> AIContext.Budget {
        let entry = await cache.model(model, provider: provider)
        return AIContext.Budget(window: entry?.contextWindow, modelOutput: entry?.maxOutputTokens, requestedOutput: requestedOutput)
    }

    // MARK: Requests

    /// Sends one provider request. With `onText`, asks for a stream and reports accumulated text at most every 32 ms.
    func requestJSON(feature: String, provider: AIProvider, model: String, body: JSON,
                     onText: (@Sendable (String) -> Void)? = nil, customTarget: (URL, String?)? = nil) async throws -> JSON {
        let endpoint: URL
        let authorization: String?
        if provider == .compatible {
            (endpoint, authorization) = try customTarget ?? compatibleTarget("chat/completions", allowPrompt: true)
        } else {
            guard let key = try keys.key(for: provider) else { throw AIError(L("Add an API key first.")) }
            endpoint = URL(string: provider.endpoint)!
            authorization = "Bearer " + String(decoding: key, as: UTF8.self)
        }
        var body = body
        if onText != nil {
            body["stream"] = true
            if provider != .openai { body["stream_options"] = ["include_usage": true] }
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = body.data()
        let urlRequest = request

        let ticket = UsageTicket.start(ledger, feature: feature, provider: provider, model: model)
        let prices = await cache.prices(model, provider: provider)
        let transport = transport
        let connectionError = AIError(L("Could not connect to the AI server or the request timed out. Check your connection."))
        return try await withDeadline(120, error: connectionError) {
            let response: HTTPStreamResponse
            do {
                response = try await transport.send(urlRequest)
            } catch is CancellationError { throw CancellationError() } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw connectionError
            }
            let requestID = response.header("x-request-id") ?? response.header("x-vercel-id")
            if (200..<300).contains(response.status), let onText, response.header("Content-Type")?.contains("text/event-stream") == true {
                onText("")
                var parser = SSEParser()
                var stream = StreamAccumulator(provider: provider)
                var wireBytes = 0
                var lastUpdate = ContinuousClock.now
                do {
                    for try await chunk in response.body {
                        wireBytes += chunk.count
                        if wireBytes > 8 * Self.maxBody { throw AIError(L("The AI response is too large.")) }
                        for event in try parser.push(chunk) {
                            if try stream.event(event), ContinuousClock.now - lastUpdate >= .milliseconds(32) {
                                onText(stream.text)
                                lastUpdate = .now
                            }
                        }
                    }
                } catch let error as AIError { throw error } catch is CancellationError { throw CancellationError() } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw AIError(L("The answer connection was interrupted."))
                }
                for event in try parser.finish() { _ = try stream.event(event) }
                onText(stream.text)
                let value = try stream.finish()
                ticket.finish(.measure(value, prices: prices))
                return value
            }
            let data = try await response.collect(limit: Self.maxBody, tooLarge: AIError(L("The AI response is too large.")),
                                                  failure: AIError(L("Could not read the AI response.")))
            guard (200..<300).contains(response.status) else {
                throw AIRequest.httpError(provider, endpoint: provider == .compatible ? endpoint.absoluteString : provider.endpoint, model: model,
                                          status: response.status, requestID: requestID, body: (try? JSON.parse(data)) ?? .null)
            }
            guard let value = try? JSON.parse(data) else { throw AIError(L("Invalid AI response format.")) }
            ticket.finish(.measure(value, prices: prices))
            return value
        }
    }

    /// One chat answer, including tools. Validates the prepared context against the model budget first.
    func chat(provider: AIProvider, model: String, messages: [AIMessage], useFiles: Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        try AIRequest.validate(model: model, messages: messages)
        let requested = try tools.load().maxOutputTokens
        if AIContext.tokens(messages) > (await contextBudget(provider, model: model, requestedOutput: requested)).input {
            throw AIError(L("Could not fit the conversation into this model's context. Choose a model with a larger context window."))
        }
        return try await withDeadline(240, error: AIError(L("The request exceeded four minutes. Narrow your question or choose another model."))) {
            try await self.send(provider: provider, model: model, messages: messages, useFiles: useFiles, onText: onText)
        }
    }

    private func send(provider: AIProvider, model: String, messages: [AIMessage], useFiles: Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var settings = try tools.load()
        settings.maxOutputTokens = await contextBudget(provider, model: model, requestedOutput: settings.maxOutputTokens).output
        settings.webSearch = switch provider {
        case .compatible: false
        case .openai: AIRequest.openAIWebSearchSupported(model)
        default: true
        }
        settings.localFiles = settings.localFiles && useFiles
        if provider == .vercel || provider == .openrouter {
            var catalog = await cache.models(for: provider)
            if catalog == nil { catalog = try? await listModels(provider) }
            if let entry = catalog?.first(where: { $0.id == model }) {
                if let limit = entry.maxOutputTokens { settings.maxOutputTokens = min(settings.maxOutputTokens, limit) }
                try AIModelCatalog.apply(entry, to: &settings, messages: messages)
            }
        }
        let customTarget = provider == .compatible ? try compatibleTarget("chat/completions", allowPrompt: true) : nil
        let tools = tools
        return try await Self.runTurn(provider: provider, model: model, messages: messages, settings: settings, current: { try tools.load() }) { provider, requestModel, body in
            try await self.requestJSON(feature: "chat", provider: provider, model: requestModel, body: body,
                                       onText: requestModel == model ? onText : nil, customTarget: customTarget)
        }
    }

    /// The bounded tool loop: at most five model rounds and six tool calls per question, two web searches.
    /// Permissions are re-read before every round and every local tool call.
    static func runTurn(
        provider: AIProvider, model: String, messages: [AIMessage], settings: AIToolSettings,
        current: () throws -> AIToolSettings,
        request: (AIProvider, String, JSON) async throws -> JSON
    ) async throws -> String {
        var body = AIRequest.body(provider, model: model, messages: messages)
        body[AIRequest.outputLimitKey(provider)] = JSON(settings.maxOutputTokens)
        let definitions = AITools.definitions(settings, webFunction: provider == .vercel || provider == .openrouter)
        var tools = definitions
        if provider == .openai {
            tools = tools.map { definition in
                var function = definition["function"]
                function["type"] = "function"
                function["strict"] = false
                return function
            }
            if settings.webSearch { tools.append(["type": "web_search", "search_context_size": "low"]) }
        }
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = "auto"
        }
        let historyKey = provider == .openai ? "input" : "messages"
        var toolCount = 0, searchCount = 0
        var sources: [JSON] = []
        var usedFiles: [String] = []
        for _ in 0..<5 {
            let latest = try current()
            if settings.localFiles && (!latest.localFiles || settings.folders.contains { folder in !latest.folders.contains { $0.id == folder.id } }) {
                throw AIError(L("Tool permissions changed, so the request stopped. Send it again."))
            }
            let value = try await request(provider, model, body)
            let calls: [JSON] = provider == .openai
                ? (value["output"].array ?? []).filter { $0["type"] == "function_call" }
                : value["choices"][0]["message"]["tool_calls"].array ?? []
            if calls.isEmpty {
                var text = AIRequest.addSources(try AIRequest.responseText(provider, value), value: value, provider: provider)
                if !sources.isEmpty { text = AIRequest.addSources(text, value: ["citations": .array(sources)], provider: provider) }
                if !usedFiles.isEmpty { text += "\n\n" + L("Local files used: ") + usedFiles.joined(separator: ", ") }
                return text
            }
            if calls.count > 6 || toolCount + calls.count > 6 {
                throw AIError(L("This question reached the six-tool limit. Narrow your question."))
            }
            toolCount += calls.count
            if provider == .openai {
                for output in value["output"].array ?? [] { body[historyKey].append(output) }
            } else {
                body[historyKey].append(value["choices"][0]["message"])
            }
            for call in calls {
                let function = provider == .openai ? call : call["function"]
                let name = function["name"].string ?? ""
                guard let arguments = try? JSON.parse(function["arguments"].string ?? "{}") else {
                    throw AIError(L("The model returned invalid tool arguments."))
                }
                guard definitions.contains(where: { $0["function"]["name"].string == name }) else {
                    throw AIError(L("The model requested a tool that was not offered."))
                }
                var result: Result<JSON, AIError>
                if name == "web_search" {
                    guard let query = arguments["query"].string, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 1000 else {
                        throw AIError(L("The search query is empty or too long."))
                    }
                    searchCount += 1
                    if searchCount > 2 {
                        result = .failure(AIError(L("Web search is limited to twice per question.")))
                    } else {
                        let search = try await request(provider, "perplexity/sonar",
                                                       ["model": "perplexity/sonar", "messages": [["role": "user", "content": .string(query)]], "max_tokens": 2048])
                        sources += search["citations"].array ?? []
                        result = .success(["result": .string(AIRequest.addSources(try AIRequest.responseText(provider, search), value: search, provider: provider))])
                    }
                } else {
                    let fresh = try current()
                    do {
                        result = .success(try AITools.executeLocal(fresh, name: name, arguments: arguments))
                        if name == "read_local_file" {
                            usedFiles.append((arguments["path"].string ?? "").replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "`", with: " "))
                        }
                    } catch {
                        result = .failure(error as? AIError ?? AIError(error.localizedDescription))
                    }
                }
                let output = switch result {
                case .success(let value): value.text
                case .failure(let error): JSON.object(["error": .string(error.message)]).text
                }
                body[historyKey].append(provider == .openai
                    ? JSON.object(["type": "function_call_output", "call_id": call["call_id"], "output": .string(output)])
                    : JSON.object(["role": "tool", "tool_call_id": call["id"], "content": .string(output)]))
            }
        }
        throw AIError(L("Tool execution took too long. Split your question into smaller parts."))
    }

    // MARK: Context

    func prepareContext(provider: AIProvider, model: String, messages: [AIMessage], compaction: ChatCompaction?,
                        progress: @escaping @Sendable () -> Void) async throws -> AIContext.Prepared {
        guard AIRequest.isValidModelID(model) else { throw AIError(L("Invalid request.")) }
        try AIContext.validateArchive(messages)
        return try await withDeadline(240, error: AIError(L("Conversation summarization timed out. Your original conversation is unchanged. Try again."))) {
            // Only gateway catalogs expose context windows. Reuse their cache before bounded discovery.
            if !(await self.cache.hasEntry(for: provider)), provider == .vercel || provider == .openrouter {
                _ = try? await withDeadline(2, error: AIError("")) { try await self.listModels(provider) }
            }
            let budget = await self.contextBudget(provider, model: model, requestedOutput: try self.tools.load().maxOutputTokens)
            return try await AIContext.prepare(messages, compaction: compaction, budget: budget, summarize: { input, allowance in
                try await self.summarize(provider: provider, model: model, messages: input, allowance: allowance)
            }, progress: progress)
        }
    }

    private func summarize(provider: AIProvider, model: String, messages: [AIMessage], allowance: Int) async throws -> String {
        let output = await contextBudget(provider, model: model, requestedOutput: 8192).output
        let body = AIRequest.summaryBody(provider, model: model, messages: messages, allowance: allowance, output: output)
        // A separate usage entry accounts for compaction. This output is never shown as the user's reply.
        let value = try await requestJSON(feature: "chat_summary", provider: provider, model: model, body: body)
        if (provider == .openai && value["status"] != "completed") || (provider != .openai && value["choices"][0]["finish_reason"] != "stop") {
            throw AIError(L("Conversation summarization was incomplete. Your original conversation is unchanged. Try again."))
        }
        return try AIRequest.responseText(provider, value)
    }
}

/// At most three conversations may reply at once. A cancelled request keeps its slot until its task ends.
struct AIRequestRegistry {
    private(set) var active: [String: Bool] = [:]
    static let limit = 3

    mutating func reserve(_ id: String) -> Bool {
        guard active[id] == nil, active.count < Self.limit else { return false }
        active[id] = false
        return true
    }

    /// Marks the request cancelled. Returns false when it is not running.
    @discardableResult
    mutating func cancel(_ id: String) -> Bool {
        guard active[id] != nil else { return false }
        active[id] = true
        return true
    }

    func isCancelled(_ id: String) -> Bool { active[id] == true }

    mutating func finish(_ id: String) { active[id] = nil }

    var count: Int { active.count }
}
