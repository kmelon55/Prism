// Adapted from Whisp RemoteTranscriptionService.swift and VercelGatewayService.swift.
// Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import Foundation

struct RemoteConfiguration: Sendable {
    let provider: SpeechProvider
    let apiKey: String
    let baseURL: String
    let model: String
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DictationHTTP {
    /// Keeps audio and credentials out of caches and never follows a provider's redirect.
    static func makeSession(requestTimeout: TimeInterval = 120, resourceTimeout: TimeInterval = 150) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static let transcription = makeSession()

    /// Reads at most `limit` bytes of the body.
    static func send(_ request: URLRequest, session: URLSession, limit: Int = 1_048_576, tooLarge: @autoclosure () -> String) async throws -> (Data, HTTPURLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DictationError(tooLarge()) }
        var data = Data()
        if http.expectedContentLength > Int64(limit) { throw DictationError(tooLarge()) }
        for try await byte in stream {
            guard data.count < limit else { throw DictationError(tooLarge()) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, http)
    }
}

/// Usage counters reported by a provider. Only counters and cost metadata, never response text.
struct UsageMeasurement: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var costKind: String = "unknown"

    /// Same precedence as the Rust ledger: provider cost, then a catalog estimate, otherwise unknown.
    init(response: Data?, prices: (input: Double, output: Double)? = nil) {
        let object = response.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let usage = object["usage"] as? [String: Any] ?? [:]
        func integer(_ key: String) -> Int? { (usage[key] as? NSNumber)?.intValue }
        func number(_ value: Any?) -> Double? {
            let parsed = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return parsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        inputTokens = integer("input_tokens") ?? integer("prompt_tokens")
        outputTokens = integer("output_tokens") ?? integer("completion_tokens")
        let gateway = { (key: String) in ((object[key] as? [String: Any])?["gateway"] as? [String: Any])?["cost"] }
        let reported = number(usage["cost"]) ?? number(gateway("providerMetadata")) ?? number(gateway("provider_metadata"))
        var estimate: Double?
        if let prices, let inputTokens, let outputTokens {
            let cost = (Double(inputTokens) * prices.input + Double(outputTokens) * prices.output) / 1_000_000
            if cost.isFinite, cost >= 0 { estimate = cost }
        }
        costUSD = reported ?? estimate
        costKind = reported != nil ? "reported" : estimate != nil ? "estimated" : "unknown"
    }

    init(inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil, costKind: String = "unknown") {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.costKind = costKind
    }

    static let local = UsageMeasurement(costUSD: 0, costKind: "local")
}

struct TranscriptionResult: Sendable {
    let text: String
    let usage: UsageMeasurement
}

/// Sends one recorded file to a remote speech-to-text provider. No automatic retries.
struct RemoteTranscriptionService: Sendable {
    let session: URLSession

    init(session: URLSession = DictationHTTP.transcription) {
        self.session = session
    }

    func transcribe(audioURL: URL, configuration: RemoteConfiguration, language: String, prompt: String, vocabulary: [String]) async throws -> TranscriptionResult {
        switch configuration.provider {
        case .vercel:
            return try await transcribeWithVercel(audioURL: audioURL, configuration: configuration, language: language, prompt: prompt)
        case .xai:
            let endpoint = try Self.endpointURL(baseURL: configuration.baseURL, suffix: "stt")
            var form = MultipartFormData()
            if language != "auto" {
                form.addField(name: "language", value: language)
                form.addField(name: "format", value: "true")
            }
            for term in vocabulary.prefix(100) { form.addField(name: "keyterm", value: term) }
            // xAI requires the file as the last field of a streamable multipart body.
            form.addFile(name: "file", filename: "recording.wav", mimeType: "audio/wav", data: try Data(contentsOf: audioURL))
            return try await perform(endpoint: endpoint, apiKey: configuration.apiKey, form: form)
        case .openai, .groq, .custom:
            let endpoint = try Self.endpointURL(baseURL: configuration.baseURL, suffix: "audio/transcriptions")
            var form = MultipartFormData()
            form.addField(name: "model", value: configuration.model)
            if language != "auto" {
                let multiLanguage = configuration.provider == .openai
                    && (configuration.model == "gpt-transcribe" || configuration.model.hasPrefix("gpt-transcribe-"))
                form.addField(name: multiLanguage ? "languages[]" : "language", value: language)
            }
            if !prompt.isEmpty { form.addField(name: "prompt", value: prompt) }
            form.addField(name: "response_format", value: "json")
            form.addFile(name: "file", filename: "recording.wav", mimeType: "audio/wav", data: try Data(contentsOf: audioURL))
            return try await perform(endpoint: endpoint, apiKey: configuration.apiKey, form: form)
        case .local:
            throw DictationError(String(localized: "This provider is not supported.", bundle: .module))
        }
    }

    private func perform(endpoint: URL, apiKey: String, form: MultipartFormData) async throws -> TranscriptionResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = form.finalizedData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("prism/0.2", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await DictationHTTP.send(request, session: session, tooLarge: Self.tooLarge)
        guard (200..<300).contains(http.statusCode) else { throw Self.requestFailed(http.statusCode) }
        struct Transcript: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Transcript.self, from: data) else { throw Self.invalidResponse }
        return TranscriptionResult(text: result.text, usage: UsageMeasurement(response: data))
    }

    private func transcribeWithVercel(audioURL: URL, configuration: RemoteConfiguration, language: String, prompt: String) async throws -> TranscriptionResult {
        let audio = try Data(contentsOf: audioURL)
        var body: [String: Any] = ["audio": audio.base64EncodedString(), "mediaType": "audio/wav"]
        if configuration.model.hasPrefix("openai/") {
            var options: [String: Any] = [:]
            if language != "auto" { options["language"] = language }
            if !prompt.isEmpty { options["prompt"] = prompt }
            if !options.isEmpty { body["providerOptions"] = ["openai": options] }
        }
        guard let endpoint = URL(string: configuration.baseURL.trimmingTrailing("/") + "/transcription-model") else { throw Self.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        request.setValue("api-key", forHTTPHeaderField: "ai-gateway-auth-method")
        request.setValue("4", forHTTPHeaderField: "ai-transcription-model-specification-version")
        request.setValue(configuration.model, forHTTPHeaderField: "ai-model-id")
        request.setValue("prism/0.1", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await DictationHTTP.send(request, session: session, tooLarge: Self.tooLarge)
        guard (200..<300).contains(http.statusCode) else { throw Self.requestFailed(http.statusCode) }
        struct Transcript: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(Transcript.self, from: data) else { throw Self.invalidResponse }
        return TranscriptionResult(text: decoded.text, usage: UsageMeasurement(response: data))
    }

    /// Appends the provider path unless the base already ends with it. Only HTTPS or local HTTP.
    static func endpointURL(baseURL: String, suffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictationError(String(localized: "Enter the API base URL.", bundle: .module)) }
        let full = trimmed.hasSuffix("/" + suffix) ? trimmed : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix
        guard let url = URL(string: full),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else {
            throw DictationError(String(localized: "Enter a valid HTTPS API base URL.", bundle: .module))
        }
        return url
    }

    // Provider error bodies are never shown; they can echo prompts or account details.
    private static func requestFailed(_ status: Int) -> DictationError {
        DictationError(String(localized: "Transcription API error (\(status)): The request could not be processed. Check the API key, model and usage limits.", bundle: .module))
    }

    private static var invalidResponse: DictationError {
        DictationError(String(localized: "Could not read the transcription API response.", bundle: .module))
    }

    private static var tooLarge: String { String(localized: "The transcription response is too large.", bundle: .module) }
}

struct MultipartFormData {
    let boundary = "WhispBoundary-\(UUID().uuidString)"
    private var data = Data()

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data fileData: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        append("\r\n")
    }

    var finalizedData: Data {
        var result = data
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) { data.append(Data(string.utf8)) }
}
