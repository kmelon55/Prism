import Foundation

/// One entry from a provider's model catalog. Prices are USD per million tokens.
public struct AIModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool?
    public var supportsImages: Bool?
    public var inputPrice: Double?
    public var outputPrice: Double?
    public var pricingVariable = false

    public init(id: String, name: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, supportsTools: Bool? = nil,
                supportsImages: Bool? = nil, inputPrice: Double? = nil, outputPrice: Double? = nil, pricingVariable: Bool = false) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsImages = supportsImages
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.pricingVariable = pricingVariable
    }
}

enum AIModelCatalog {
    /// Provider catalogs quote USD per token; the UI uses USD per million tokens.
    static func millionTokenPrice(_ value: JSON) -> Double? {
        guard let base = value.double ?? value.string.flatMap(Double.init) else { return nil }
        let price = base * 1_000_000
        return price.isFinite && price >= 0 ? price : nil
    }

    private static func hasText(_ value: JSON) -> Bool {
        value.array?.contains("text") == true
    }

    /// OpenAI's list endpoint has no modality metadata. Keep text-family candidates and exclude known specialized
    /// endpoints; listing never proves inference permission.
    static func openAITextCandidate(_ id: String) -> Bool {
        let base = id.hasPrefix("ft:") ? String(id.dropFirst(3).split(separator: ":", omittingEmptySubsequences: false).first ?? "") : id
        let family = base.hasPrefix("gpt-") || ["o1", "o3", "o4"].contains { base == $0 || base.hasPrefix("\($0)-") }
        let specialized = ["audio", "realtime", "transcrib", "tts", "image", "search", "instruct", "chat-latest"].contains { base.contains($0) }
        return family && !specialized
    }

    static func parse(_ provider: AIProvider, _ value: JSON) throws -> [AIModel] {
        guard let rows = value["data"].array else { throw AIError(L("Invalid model catalog format.")) }
        if rows.count > 10_000 { throw AIError(L("The model catalog is too large.")) }
        var models: [String: AIModel] = [:]
        for row in rows {
            guard let id = row["id"].string, AIRequest.isValidModelID(id), !id.hasSuffix(":batch") else { continue }
            let supported = switch provider {
            case .vercel: row["type"] == "language" && hasText(row["modalities"]["input"]) && hasText(row["modalities"]["output"])
            case .openrouter: hasText(row["architecture"]["input_modalities"]) && hasText(row["architecture"]["output_modalities"])
            case .openai: openAITextCandidate(id)
            case .compatible: true
            }
            guard supported, models[id] == nil else { continue }
            let rawName = row["name"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? id
            let maxTokens = (row["max_tokens"].uint ?? row["top_provider"]["max_completion_tokens"].uint).flatMap { $0 > 0 && $0 <= UInt64(UInt32.max) ? Int($0) : nil }
            let modalities: [JSON]? = switch provider {
            case .vercel: row["modalities"]["input"].array
            case .openrouter: row["architecture"]["input_modalities"].array
            default: nil
            }
            let pricing = row["pricing"]
            let priced = provider != .compatible
            models[id] = AIModel(
                id: id,
                name: String(rawName.prefix(180)),
                contextWindow: (row["context_window"].uint ?? row["context_length"].uint).map { Int(min($0, UInt64(Int.max))) },
                maxOutputTokens: maxTokens,
                supportsTools: row["supported_parameters"].array.map { $0.contains("tools") },
                supportsImages: modalities.map { $0.contains("image") },
                inputPrice: priced ? millionTokenPrice(pricing[provider == .openrouter ? "prompt" : "input"]) : nil,
                outputPrice: priced ? millionTokenPrice(pricing[provider == .openrouter ? "completion" : "output"]) : nil,
                pricingVariable: ["overrides", "input_tiers", "output_tiers"].contains { pricing[$0].array?.isEmpty == false }
                    || pricing["varies_by_provider"].bool == true
            )
        }
        return models.values.sorted { $0.id < $1.id }
    }

    /// Rejects requests a known catalog entry cannot serve. Web search is dropped quietly; explicit file tools fail.
    static func apply(_ model: AIModel, to settings: inout AIToolSettings, messages: [AIMessage]) throws {
        if model.supportsImages == false && messages.contains(where: { $0.image != nil }) {
            throw AIError(L("This model does not support images. Choose an image-capable model."))
        }
        if model.supportsTools == false {
            settings.webSearch = false
            if settings.localFiles {
                throw AIError(L("This model does not support tools. Turn off Files or choose a tool-capable model."))
            }
        }
    }
}

/// Catalogs fetched in this process, reused for ten minutes for prices, context windows and capabilities.
actor AIModelCache {
    static let shared = AIModelCache()
    private var entries: [AIProvider: (date: Date, models: [AIModel])] = [:]

    func store(_ models: [AIModel], for provider: AIProvider) {
        entries[provider] = (Date(), models)
    }

    func models(for provider: AIProvider, maxAge: TimeInterval = 600) -> [AIModel]? {
        guard let entry = entries[provider], Date().timeIntervalSince(entry.date) < maxAge else { return nil }
        return entry.models
    }

    func hasEntry(for provider: AIProvider) -> Bool { entries[provider] != nil }

    /// Any cached entry regardless of age, as the Rust context budget reads it.
    func model(_ id: String, provider: AIProvider) -> AIModel? {
        entries[provider]?.models.first { $0.id == id }
    }

    func prices(_ id: String, provider: AIProvider) -> (Double, Double)? {
        guard let entry = models(for: provider)?.first(where: { $0.id == id }), let input = entry.inputPrice, let output = entry.outputPrice else { return nil }
        return (input, output)
    }
}

/// Price display used by settings, pickers and usage.
public enum AIPrice {
    public static func format(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return L("Not provided") }
        if value == 0 { return "$0" }
        if value < 0.0001 { return "<$0.0001" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        return "$" + (formatter.string(from: value as NSNumber) ?? String(value))
    }

    /// Five-step price meter: $0 / <$0.1 / <$0.5 / <$2 / <$10 / $10+.
    public static func level(_ price: Double?) -> Int? {
        guard let price, price.isFinite, price >= 0 else { return nil }
        if price == 0 { return 0 }
        return [0.1, 0.5, 2, 10].filter { price >= $0 }.count + 1
    }
}
