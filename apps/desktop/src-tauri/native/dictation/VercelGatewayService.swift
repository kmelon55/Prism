// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import Foundation

struct VercelGatewayService {
    let session: URLSession
    let onUsage: ((Data) async -> Void)?
    init(session: URLSession = TranscriptionHTTP.session, onUsage: ((Data) async -> Void)? = nil) { self.session = session; self.onUsage = onUsage }
    func transcribe(
        audioURL: URL,
        apiKey: String,
        baseURL: String,
        model: String,
        language: String,
        prompt: String
    ) async throws -> String {
        let audio = try Data(contentsOf: audioURL)
        var body: [String: Any] = [
            "audio": audio.base64EncodedString(),
            "mediaType": "audio/wav"
        ]

        if model.hasPrefix("openai/") {
            var options: [String: Any] = [:]
            if language != "auto" { options["language"] = language }
            if !prompt.isEmpty { options["prompt"] = prompt }
            if !options.isEmpty { body["providerOptions"] = ["openai": options] }
        }

        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(string: trimmed + "/transcription-model") else {
            throw GatewayError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        request.setValue("api-key", forHTTPHeaderField: "ai-gateway-auth-method")
        request.setValue("4", forHTTPHeaderField: "ai-transcription-model-specification-version")
        request.setValue(model, forHTTPHeaderField: "ai-model-id")
        request.setValue("prism/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await TranscriptionHTTP.send(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayError.requestFailed(status: http.statusCode, message: "요청을 처리하지 못했습니다. API 키, 모델과 사용 한도를 확인하세요.")
        }
        await onUsage?(data)
        guard let decoded = try? JSONDecoder().decode(GatewayTranscript.self, from: data) else {
            throw GatewayError.invalidResponse
        }
        return decoded.text
    }

    private func extractError(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "알 수 없는 Gateway 응답" }

        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return String(data: data, encoding: .utf8) ?? "알 수 없는 Gateway 응답"
    }
}

private struct GatewayTranscript: Decodable {
    let text: String
}

enum GatewayError: LocalizedError {
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Vercel Gateway 응답을 읽지 못했습니다."
        case .requestFailed(let status, let message): return "Vercel Gateway 오류 (\(status)): \(message)"
        }
    }
}
