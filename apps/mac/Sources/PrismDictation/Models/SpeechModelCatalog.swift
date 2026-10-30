// Catalog decoding, filtering, ordering and pricing ported from Whisp VercelModelCatalog.swift
// (via `dictation/catalog.rs`). Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import Foundation

struct SpeechModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let ownedBy: String
    /// False for realtime-only and diarization rows, which this flow cannot use.
    let batchCompatible: Bool
    let unavailableReason: String?
    let free: Bool
    let pricing: [String: String]

    /// Duration price per hour first, then audio input/output per million tokens. Prices come only from the API.
    var priceText: String {
        if free { return String(localized: "Free", bundle: .module) }
        func number(_ key: String) -> Double? { pricing[key].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        func format(_ value: Double) -> String { formatter.string(from: value as NSNumber) ?? "\(value)" }
        if let duration = number("transcription_duration_cost_per_second") {
            return "$\(format(duration * 3600))/" + String(localized: "hr", bundle: .module)
        }
        if let input = number("audio_input_token_cost") ?? number("input"), let output = number("output") {
            return "$\(format(input * 1e6)) / $\(format(output * 1e6)) · " + String(localized: "input / output · per 1M tokens", bundle: .module)
        }
        return String(localized: "Price unavailable", bundle: .module)
    }
}

struct SpeechModelCatalog: Sendable {
    enum Mode: Sendable { case catalog, fixed }
    var models: [SpeechModel]
    var source: String
    var mode: Mode

    static let preferredOrder = [
        "openai/gpt-4o-mini-transcribe", "openai/gpt-4o-transcribe", "google/gemini-3.5-transcribe", "spacexai/grok-stt",
        "fish-audio/transcribe-1-free", "fish-audio/transcribe-1", "openai/whisper-1", "google/gemini-3.5-transcribe-live",
        "openai/gpt-realtime-whisper",
    ]

    /// The models endpoint for a provider. Built-in providers only ever use their own host.
    static func endpoint(provider: SpeechProvider, baseURL: String) throws -> String {
        var probe = DictationSettings().changingProvider(to: provider)
        probe.model = "catalog"
        probe.baseURL = baseURL
        try probe.validate()
        switch provider {
        case .local: throw DictationError(String(localized: "Choose a local model file.", bundle: .module))
        case .vercel: return "https://ai-gateway.vercel.sh/v1/models"
        default:
            var base = baseURL.trimmingTrailing("/")
            if base.hasSuffix("/audio/transcriptions") { base.removeLast("/audio/transcriptions".count) }
            return base + "/models"
        }
    }

    /// Lists file-transcription models the provider actually returns. xAI selects its engine server-side.
    static func load(provider: SpeechProvider, baseURL: String, apiKey: String?, session: URLSession = catalogSession) async throws -> SpeechModelCatalog {
        let source = try endpoint(provider: provider, baseURL: baseURL)
        if provider == .xai { return SpeechModelCatalog(models: [], source: "https://api.x.ai/v1/stt", mode: .fixed) }
        let body = try await fetch(source, apiKey: provider == .vercel ? nil : apiKey, session: session)
        return SpeechModelCatalog(models: try decode(provider: provider, body: body), source: source, mode: .catalog)
    }

    static let catalogSession = DictationHTTP.makeSession(requestTimeout: 20, resourceTimeout: 20)

    /// GET only, no redirects, at most 4 MiB, and provider error bodies are never shown.
    static func fetch(_ source: String, apiKey: String?, session: URLSession = catalogSession) async throws -> Data {
        guard let url = URL(string: source) else { throw DictationError(String(localized: "Enter a valid HTTPS API base URL.", bundle: .module)) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await DictationHTTP.send(request, session: session, limit: 4 * 1_048_576,
                                                         tooLarge: String(localized: "The model list response is too large.", bundle: .module))
        } catch let error as DictationError {
            throw error
        } catch {
            throw DictationError(String(localized: "Could not connect to the model list. Check the network and API address.", bundle: .module))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DictationError(String(localized: "Model list error (\(http.statusCode)). Check the API key and access, then refresh.", bundle: .module))
        }
        return data
    }

    static func decode(provider: SpeechProvider, body: Data) throws -> [SpeechModel] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let rows = object["data"] as? [[String: Any]] else {
            throw DictationError(String(localized: "Could not read the model list response.", bundle: .module))
        }
        func contains(_ row: [String: Any], _ field: String, _ member: String) -> Bool {
            (row[field] as? [Any])?.contains { $0 as? String == member } ?? false
        }
        func text(_ value: Any?, limit: Int) -> String { String(((value as? String) ?? "").prefix(limit)) }
        var seen = Set<String>()
        var models: [SpeechModel] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 200,
                  id.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else { continue }
            if row["active"] as? Bool == false { continue }
            let transcription = row["type"] as? String == "transcription"
            let include = switch provider {
            case .vercel: transcription && contains(row, "supported_specifications", "v4")
            case .openai: documentedOpenAI(id)
            case .groq: id == "whisper-large-v3" || id == "whisper-large-v3-turbo"
            // Compatible servers must advertise transcription explicitly; an audio modality is not enough.
            case .custom: transcription || contains(row, "supported_endpoints", "/v1/audio/transcriptions")
            case .local, .xai: false
            }
            guard include, seen.insert(id).inserted else { continue }
            let realtime = contains(row, "tags", "websocket-realtime") || id.hasSuffix("-live") || id.contains("realtime")
            let diarize = provider == .openai && id.contains("diarize")
            var pricing: [String: String] = [:]
            for (key, value) in row["pricing"] as? [String: Any] ?? [:] {
                if let string = value as? String { pricing[key] = string } else if let number = value as? NSNumber { pricing[key] = number.stringValue }
            }
            models.append(SpeechModel(
                id: id, name: (row["name"] as? String).map { String($0.prefix(200)) } ?? id,
                description: text(row["description"], limit: 600), ownedBy: text(row["owned_by"], limit: 100),
                batchCompatible: !realtime && !diarize,
                unavailableReason: realtime ? String(localized: "Realtime-only model", bundle: .module)
                    : diarize ? String(localized: "Speaker diarization options are not supported yet.", bundle: .module) : nil,
                free: contains(row, "tags", "free"), pricing: pricing))
        }
        return models.sorted {
            let left = preferredOrder.firstIndex(of: $0.id) ?? .max
            let right = preferredOrder.firstIndex(of: $1.id) ?? .max
            return left != right ? left < right : $0.name.lowercased() < $1.name.lowercased()
        }
    }

    /// Documented OpenAI file-transcription families and their dated snapshots. Audio-chat models are not STT.
    static func documentedOpenAI(_ id: String) -> Bool {
        ["whisper-1", "gpt-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "gpt-4o-transcribe-diarize"].contains { base in
            guard id != base else { return true }
            guard id.hasPrefix(base + "-") else { return false }
            let date = Array(id.dropFirst(base.count + 1).utf8)
            return date.count == 10 && date.enumerated().allSatisfy { index, byte in
                index == 4 || index == 7 ? byte == UInt8(ascii: "-") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            }
        }
    }
}
