import Foundation
struct ProcessingSelection: Codable { let provider: String; let model: String; var modelName: String? }
struct UsageMeasurement: Decodable {
    var inputTokens: UInt64?
    var outputTokens: UInt64?
    var costUsd: Double?
    var costKind: String?
}
struct ProcessingResult: Decodable {
    var text: String?
    var error: String?
    var usage: UsageMeasurement?
}
struct UsageReceipt {
    var cost = 0.0
    var tokens: UInt64 = 0
    var hasTokens = false
    var known = 0
    var unknown = 0
    var estimated = false
    mutating func add(_ usage: UsageMeasurement) {
        if let value = usage.costUsd, value.isFinite, value >= 0 { cost += value; known += 1 } else { unknown += 1 }
        if let input = usage.inputTokens, let output = usage.outputTokens { tokens += input + output; hasTokens = true }
        estimated = estimated || usage.costKind == "estimated"
    }
    func label(_ language: AppLanguage) -> String {
        let amount = cost > 0 && cost < 0.0001 ? "<$0.0001" : String(format: "$%.4f", cost)
        let costLabel = known == 0 ? language.text("비용 미제공", "Cost unavailable") : (estimated ? "≈" : "") + amount + (unknown > 0 ? " + ?" : "")
        return (hasTokens ? "\(tokens) " + language.text("토큰", "tokens") + " · " : "") + costLabel
    }
}
