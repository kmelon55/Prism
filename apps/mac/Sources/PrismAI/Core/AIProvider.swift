import Foundation

/// Localized text from this module's strings table.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// A user-facing failure. Messages never contain keys, raw provider bodies or echoed prompts.
public struct AIError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    static let cancelled = AIError(L("Request stopped. The provider may bill usage already processed."))
}

public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case vercel, openai, openrouter, compatible

    public var id: String { rawValue }

    /// Keychain account and usage ledger provider name.
    public var account: String { rawValue }

    public var name: String {
        switch self {
        case .vercel: "Vercel AI Gateway"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .compatible: "OpenAI-compatible"
        }
    }

    /// Short name for compact pickers.
    public var shortName: String { self == .vercel ? "Vercel" : name }

    public var summary: String {
        switch self {
        case .vercel: L("Use models from many companies with one Gateway key")
        case .openai: L("Connect directly with your OpenAI account")
        case .openrouter: L("Use models from many companies with one OpenRouter key")
        case .compatible: L("Connect a local model or your own API server")
        }
    }

    public var keyURL: URL? {
        switch self {
        case .vercel: URL(string: "https://vercel.com/d?title=AI+Gateway+API+Keys&to=%2F%5Bteam%5D%2F~%2Fai-gateway%2Fapi-keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .compatible: nil
        }
    }

    /// Fixed inference endpoint. Custom servers resolve theirs from the saved connection.
    public var endpoint: String {
        switch self {
        case .openai: "https://api.openai.com/v1/responses"
        case .openrouter: "https://openrouter.ai/api/v1/chat/completions"
        case .vercel: "https://ai-gateway.vercel.sh/v1/chat/completions"
        case .compatible: "chat/completions"
        }
    }

    var catalogEndpoint: String? {
        switch self {
        case .openai: "https://api.openai.com/v1/models"
        case .openrouter: "https://openrouter.ai/api/v1/models"
        case .vercel: "https://ai-gateway.vercel.sh/v1/models"
        case .compatible: nil
        }
    }

    var diagnosticName: String { self == .compatible ? "OpenAI-compatible API" : name }

    /// Settings and pickers list connections in the Tauri order.
    public static let displayOrder: [AIProvider] = [.compatible, .vercel, .openai, .openrouter]
}

/// A JPEG screenshot or attachment, stored as a data URL exactly as the Tauri app does.
public struct ChatImage: Codable, Equatable, Hashable, Sendable {
    public var dataUrl: String
    public init(dataUrl: String) { self.dataUrl = dataUrl }
}

/// One provider message: `user`, `assistant` or (for summaries and rewrites) `system`.
public struct AIMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    public var image: ChatImage?

    public init(role: String, content: String, image: ChatImage? = nil) {
        self.role = role
        self.content = content
        self.image = image
    }
}

/// Saved provider and model, `ai-selection-v1.json`.
public struct AISelection: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var model: String
    public var modelName: String?

    public init(provider: AIProvider, model: String, modelName: String? = nil) {
        self.provider = provider
        self.model = model
        self.modelName = modelName
    }

    public static let empty = AISelection(provider: .vercel, model: "")

    public var displayName: String { modelName.flatMap { $0.isEmpty ? nil : $0 } ?? model }

    func validate() throws {
        if !AIRequest.isValidModelID(model)
            || modelName.map({ $0.utf8.count > 720 || $0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }) == true {
            throw AIError(L("Choose a valid model."))
        }
    }
}
