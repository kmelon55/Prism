import Foundation

/// Model names and IDs use different word separators. Version dots stay meaningful, while spacing differences,
/// full-width characters and word order are ignored. Ported from `model-picker/modelSearch.ts`.
struct ModelSearch: Sendable {
    private let joined: String
    private let terms: [String]

    init(_ query: String) {
        let normalized = Self.normalize(query)
        joined = Self.compact(normalized)
        terms = Self.split(normalized)
    }

    func matches(name: String, id: String, ownedBy: String = "") -> Bool {
        guard !terms.isEmpty else { return true }
        let fields = [name, id, ownedBy].map { Self.compact(Self.normalize($0)) }
        return fields.contains { $0.contains(joined) } || terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }

    func matches(_ model: AIModel) -> Bool { matches(name: model.name, id: model.id) }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .dashPunctuation || scalar == "_" || scalar == "/" || scalar == ":"
    }

    private static func split(_ value: String) -> [String] {
        var terms: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isSeparator(scalar) {
                if !current.isEmpty { terms.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { terms.append(String(current)) }
        return terms
    }

    private static func compact(_ value: String) -> String {
        split(value).joined()
    }
}

enum ModelSort: String, CaseIterable, Sendable {
    case name, input, output

    func sorted(_ models: [AIModel]) -> [AIModel] {
        models.sorted { a, b in
            switch self {
            case .input where (a.inputPrice ?? .infinity) != (b.inputPrice ?? .infinity):
                return (a.inputPrice ?? .infinity) < (b.inputPrice ?? .infinity)
            case .output where (a.outputPrice ?? .infinity) != (b.outputPrice ?? .infinity):
                return (a.outputPrice ?? .infinity) < (b.outputPrice ?? .infinity)
            default:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// Reference speed observations from public Vercel model pages (2026-10-28), not a latency prediction.
enum ModelSpeedReference {
    struct Entry { let tokens: Int; let first: Double; let route: String }
    static let entries: [String: Entry] = [
        "google/gemini-2.5-flash-lite": Entry(tokens: 477, first: 0.3, route: "Google Vertex AI"),
        "google/gemini-3.1-flash-lite": Entry(tokens: 276, first: 0.7, route: "Google Vertex AI"),
        "mistral/mistral-nemo": Entry(tokens: 42, first: 0.3, route: "DeepInfra"),
    ]

    static func entry(_ model: String, provider: AIProvider) -> Entry? {
        provider == .vercel ? entries[model] : nil
    }

    static func level(_ entry: Entry) -> Int {
        [50, 100, 200, 400].filter { entry.tokens >= $0 }.count + 1
    }
}
