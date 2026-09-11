// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import Foundation

struct RemoteTranscriptionService {
    let session: URLSession
    let onUsage: ((Data) async -> Void)?
    init(session: URLSession = TranscriptionHTTP.session, onUsage: ((Data) async -> Void)? = nil) { self.session = session; self.onUsage = onUsage }
    func transcribe(
        audioURL: URL,
        configuration: RemoteConfiguration,
        language: String,
        prompt: String,
        vocabulary: [String]
    ) async throws -> String {
        switch configuration.provider {
        case .vercel:
            return try await VercelGatewayService(session: session, onUsage: onUsage).transcribe(
                audioURL: audioURL,
                apiKey: configuration.apiKey,
                baseURL: configuration.baseURL,
                model: configuration.model,
                language: language,
                prompt: prompt
            )
        case .xAI:
            return try await transcribeWithXAI(
                audioURL: audioURL,
                configuration: configuration,
                language: language,
                vocabulary: vocabulary
            )
        case .openAI, .groq, .custom:
            return try await transcribeWithOpenAICompatibleAPI(
                audioURL: audioURL,
                configuration: configuration,
                language: language,
                prompt: prompt
            )
        }
    }

    private func transcribeWithOpenAICompatibleAPI(
        audioURL: URL,
        configuration: RemoteConfiguration,
        language: String,
        prompt: String
    ) async throws -> String {
        let endpoint = try endpointURL(
            baseURL: configuration.baseURL,
            suffix: "audio/transcriptions",
            acceptedSuffix: "/audio/transcriptions"
        )
        var form = MultipartFormData()
        form.addField(name: "model", value: configuration.model)
        if language != "auto" {
            let multiLanguage = configuration.provider == .openAI && (configuration.model == "gpt-transcribe" || configuration.model.hasPrefix("gpt-transcribe-"))
            form.addField(name: multiLanguage ? "languages[]" : "language", value: language)
        }
        if !prompt.isEmpty { form.addField(name: "prompt", value: prompt) }
        form.addField(name: "response_format", value: "json")
        form.addFile(name: "file", filename: "recording.wav", mimeType: "audio/wav", data: try Data(contentsOf: audioURL))
        return try await perform(endpoint: endpoint, apiKey: configuration.apiKey, form: form)
    }

    private func transcribeWithXAI(
        audioURL: URL,
        configuration: RemoteConfiguration,
        language: String,
        vocabulary: [String]
    ) async throws -> String {
        let endpoint = try endpointURL(baseURL: configuration.baseURL, suffix: "stt", acceptedSuffix: "/stt")
        var form = MultipartFormData()
        if language != "auto" {
            form.addField(name: "language", value: language)
            form.addField(name: "format", value: "true")
        }
        for term in vocabulary.prefix(100) {
            form.addField(name: "keyterm", value: term)
        }
        // xAI는 streamable multipart에서 file을 마지막 field로 요구합니다.
        form.addFile(name: "file", filename: "recording.wav", mimeType: "audio/wav", data: try Data(contentsOf: audioURL))
        return try await perform(endpoint: endpoint, apiKey: configuration.apiKey, form: form)
    }

    private func perform(endpoint: URL, apiKey: String, form: MultipartFormData) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = form.finalizedData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("prism/0.2", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await TranscriptionHTTP.send(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw RemoteAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteAPIError.requestFailed(status: http.statusCode, message: "요청을 처리하지 못했습니다. API 키, 모델과 사용 한도를 확인하세요.")
        }
        await onUsage?(data)
        guard let result = try? JSONDecoder().decode(RemoteTranscript.self, from: data) else {
            throw RemoteAPIError.invalidResponse
        }
        return result.text
    }

    private func endpointURL(baseURL: String, suffix: String, acceptedSuffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemoteAPIError.missingBaseURL }
        let full = trimmed.hasSuffix(acceptedSuffix)
            ? trimmed
            : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix
        guard let url = URL(string: full), url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(url.host ?? "")) else {
            throw RemoteAPIError.invalidBaseURL
        }
        return url
    }

    private func extractError(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "알 수 없는 API 응답"
        }
        if let message = object["message"] as? String { return message }
        if let detail = object["detail"] as? String { return detail }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return String(data: data, encoding: .utf8) ?? "알 수 없는 API 응답"
    }
}

private struct RemoteTranscript: Decodable {
    let text: String
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

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }
}

enum RemoteAPIError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: return "API Base URL을 입력해 주세요."
        case .invalidBaseURL: return "올바른 HTTPS API Base URL을 입력해 주세요."
        case .invalidResponse: return "전사 API 응답을 읽지 못했습니다."
        case .requestFailed(let status, let message): return "전사 API 오류 (\(status)): \(message)"
        }
    }
}
