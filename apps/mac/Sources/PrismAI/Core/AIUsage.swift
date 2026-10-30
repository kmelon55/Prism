import Foundation
import PrismKit

/// Token and cost measurements for one request. Reported provider cost wins over a catalog-price estimate.
public struct UsageMeasurement: Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    public var costKind = "unknown"

    static func measure(_ value: JSON, prices: (Double, Double)?) -> UsageMeasurement {
        let usage = value["usage"]
        let input = (usage["input_tokens"].uint ?? usage["prompt_tokens"].uint).map(Int.init)
        let output = (usage["output_tokens"].uint ?? usage["completion_tokens"].uint).map(Int.init)
        func number(_ value: JSON) -> Double? {
            guard let number = value.double ?? value.string.flatMap(Double.init), number.isFinite, number >= 0 else { return nil }
            return number
        }
        let reported = number(usage["cost"]) ?? number(value["providerMetadata"]["gateway"]["cost"]) ?? number(value["provider_metadata"]["gateway"]["cost"])
        var estimate: Double?
        if let (inputPrice, outputPrice) = prices, let input, let output {
            let cost = (Double(input) * inputPrice + Double(output) * outputPrice) / 1_000_000
            if cost.isFinite && cost >= 0 { estimate = cost }
        }
        return UsageMeasurement(inputTokens: input, outputTokens: output, costUSD: reported ?? estimate,
                                costKind: reported != nil ? "reported" : estimate != nil ? "estimated" : "unknown")
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var knownCostUSD = 0.0
    public var unknownCostRequests = 0
    public var unknownTokenRequests = 0
    public var estimatedRequests = 0

    public var tokens: Int { inputTokens + outputTokens }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(requests: lhs.requests + rhs.requests, inputTokens: lhs.inputTokens + rhs.inputTokens,
                    outputTokens: lhs.outputTokens + rhs.outputTokens, knownCostUSD: lhs.knownCostUSD + rhs.knownCostUSD,
                    unknownCostRequests: lhs.unknownCostRequests + rhs.unknownCostRequests,
                    unknownTokenRequests: lhs.unknownTokenRequests + rhs.unknownTokenRequests,
                    estimatedRequests: lhs.estimatedRequests + rhs.estimatedRequests)
    }
}

public struct UsageRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var startedAt: Date
    public var feature: String
    public var provider: String
    public var model: String
    public var status: String
    public var measurement: UsageMeasurement
}

public struct UsageBreakdown: Equatable, Sendable {
    public var feature: String
    public var provider: String
    public var model: String
    public var totals: UsageTotals
}

public struct UsageDay: Equatable, Sendable {
    public var day: String
    public var totals: UsageTotals
}

public struct UsageSummary: Equatable, Sendable {
    public var month = UsageTotals()
    public var allTime = UsageTotals()
    public var breakdown: [UsageBreakdown] = []
    public var daily: [UsageDay] = []
    public var recent: [UsageRow] = []
}

/// `ai-usage-v1.sqlite`: a local metadata ledger. Never stores prompts, transcripts, audio, keys or response bodies.
/// A row is inserted before dispatch so interrupted requests remain visibly unconfirmed.
public final class UsageLedger: Sendable {
    let database: SQLiteDatabase

    public init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        try Self.prepare(database)
    }

    init(database: SQLiteDatabase) throws {
        self.database = database
        try Self.prepare(database)
    }

    private static func prepare(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS requests (
                id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, feature TEXT NOT NULL,
                provider TEXT NOT NULL, model TEXT NOT NULL, status TEXT NOT NULL,
                input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, cost_kind TEXT NOT NULL DEFAULT 'unknown'
            ); CREATE INDEX IF NOT EXISTS requests_started ON requests(started_at);
            """)
    }

    public static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func insert(feature: String, provider: String, model: String, at time: Int64 = UsageLedger.now) throws -> Int64 {
        try database.transaction {
            try database.run("INSERT INTO requests(started_at,feature,provider,model,status) VALUES (?,?,?,?,'unconfirmed')",
                             [time, feature, provider, model])
            return database.lastInsertRowID
        }
    }

    func update(_ id: Int64, measurement: UsageMeasurement, status: String) throws {
        try database.run("UPDATE requests SET status=?,input_tokens=?,output_tokens=?,cost_usd=?,cost_kind=? WHERE id=?",
                         [status, measurement.inputTokens, measurement.outputTokens, measurement.costUSD, measurement.costKind, id])
    }

    private static let totalsSQL = "COUNT(*) AS requests,COALESCE(SUM(input_tokens),0) AS input,COALESCE(SUM(output_tokens),0) AS output,COALESCE(SUM(cost_usd),0) AS cost,COALESCE(SUM(cost_usd IS NULL),0) AS unknown_cost,COALESCE(SUM(input_tokens IS NULL OR output_tokens IS NULL),0) AS unknown_tokens,COALESCE(SUM(cost_kind='estimated'),0) AS estimated"

    private static func totals(_ row: SQLiteRow) -> UsageTotals {
        UsageTotals(requests: Int(row.int("requests")), inputTokens: Int(row.int("input")), outputTokens: Int(row.int("output")),
                    knownCostUSD: row.double("cost"), unknownCostRequests: Int(row.int("unknown_cost")),
                    unknownTokenRequests: Int(row.int("unknown_tokens")), estimatedRequests: Int(row.int("estimated")))
    }

    public func summary(since: Int64) throws -> UsageSummary {
        guard since >= 0, since <= Self.now + 1000 else { throw AIError(L("Invalid usage period.")) }
        var summary = UsageSummary()
        summary.month = try database.query("SELECT \(Self.totalsSQL) FROM requests WHERE started_at>=?", [since], row: Self.totals).first ?? UsageTotals()
        summary.allTime = try database.query("SELECT \(Self.totalsSQL) FROM requests", row: Self.totals).first ?? UsageTotals()
        summary.recent = try database.query("SELECT id,started_at,feature,provider,model,status,input_tokens,output_tokens,cost_usd,cost_kind FROM requests ORDER BY id DESC LIMIT 12") { row in
            UsageRow(id: row.int("id"), startedAt: Date(timeIntervalSince1970: Double(row.int("started_at")) / 1000),
                     feature: row.string("feature") ?? "", provider: row.string("provider") ?? "", model: row.string("model") ?? "",
                     status: row.string("status") ?? "",
                     measurement: UsageMeasurement(inputTokens: row.optionalInt("input_tokens").map(Int.init),
                                                   outputTokens: row.optionalInt("output_tokens").map(Int.init),
                                                   costUSD: row.isNull("cost_usd") ? nil : row.double("cost_usd"),
                                                   costKind: row.string("cost_kind") ?? "unknown"))
        }
        summary.breakdown = try database.query("SELECT feature,provider,model,\(Self.totalsSQL) FROM requests WHERE started_at>=? GROUP BY feature,provider,model ORDER BY COALESCE(SUM(cost_usd),0) DESC", [since]) { row in
            UsageBreakdown(feature: row.string("feature") ?? "", provider: row.string("provider") ?? "", model: row.string("model") ?? "", totals: Self.totals(row))
        }
        summary.daily = try database.query("SELECT strftime('%Y-%m-%d',started_at/1000,'unixepoch','localtime') AS day,\(Self.totalsSQL) FROM requests WHERE started_at>=? GROUP BY day ORDER BY day", [since]) { row in
            UsageDay(day: row.string("day") ?? "", totals: Self.totals(row))
        }
        return summary
    }

    /// The first moment of the current local month, in milliseconds.
    public static func monthStart(_ now: Date = Date(), calendar: Calendar = .current) -> Int64 {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        return Int64(start.timeIntervalSince1970 * 1000)
    }
}

/// One in-flight request in the ledger. Finishing records measurements; dropping it unfinished leaves "unconfirmed".
struct UsageTicket: Sendable {
    let ledger: UsageLedger?
    let id: Int64?

    static func start(_ ledger: UsageLedger?, feature: String, provider: AIProvider, model: String) -> UsageTicket {
        let id = try? ledger?.insert(feature: feature, provider: provider.account, model: model)
        Task { @MainActor in NotificationCenter.default.post(name: .prismAIUsageChanged, object: nil) }
        return UsageTicket(ledger: ledger, id: id)
    }

    func finish(_ measurement: UsageMeasurement, status: String = "completed") {
        if let ledger, let id { try? ledger.update(id, measurement: measurement, status: status) }
        Task { @MainActor in NotificationCenter.default.post(name: .prismAIUsageChanged, object: nil) }
    }
}

/// Chart and label helpers shared by the usage view.
public enum UsagePresentation {
    public enum Metric: String, CaseIterable, Sendable { case cost, tokens, requests }
    public enum Grouping: String, CaseIterable, Sendable { case feature, model, provider }

    public static func featureName(_ feature: String) -> String {
        switch feature {
        case "transcription": L("Transcription")
        case "cleanup": L("Refine speech")
        case "prompt": L("Structure prompt")
        case "chat": L("AI Chat")
        case "chat_summary": L("Conversation summary")
        default: feature
        }
    }

    public static func providerName(_ provider: String) -> String {
        switch provider {
        case "vercel": "Vercel AI Gateway"
        case "openai": "OpenAI"
        case "openrouter": "OpenRouter"
        case "groq": "Groq"
        case "xai": "xAI"
        case "local": L("Local")
        case "custom": L("Custom")
        case "compatible": "OpenAI-compatible"
        default: provider
        }
    }

    public static func cost(_ totals: UsageTotals) -> String {
        if totals.requests == 0 { return AIPrice.format(0) }
        if totals.unknownCostRequests == totals.requests { return L("Cost unavailable") }
        return (totals.estimatedRequests > 0 ? "≈ " : "") + AIPrice.format(totals.knownCostUSD) + (totals.unknownCostRequests > 0 ? " + ?" : "")
    }

    public static func rowCost(_ row: UsageRow) -> String {
        guard let cost = row.measurement.costUSD else { return L("Cost unavailable") }
        return (row.measurement.costKind == "estimated" ? "≈ " : "") + AIPrice.format(cost)
    }

    public static func value(_ totals: UsageTotals, _ metric: Metric) -> Double {
        switch metric {
        case .cost: totals.knownCostUSD
        case .tokens: Double(totals.tokens)
        case .requests: Double(totals.requests)
        }
    }

    public static func label(_ totals: UsageTotals, _ metric: Metric) -> String {
        switch metric {
        case .cost: cost(totals)
        case .tokens: totals.tokens.formatted() + (totals.unknownTokenRequests > 0 ? " + ?" : "")
        case .requests: totals.requests.formatted()
        }
    }

    public static func group(_ rows: [UsageBreakdown], by grouping: Grouping, metric: Metric) -> [(name: String, totals: UsageTotals)] {
        var grouped: [String: UsageTotals] = [:]
        for row in rows {
            let key = switch grouping {
            case .model: "\(row.provider) / \(row.model)"
            case .feature: row.feature
            case .provider: row.provider
            }
            grouped[key] = (grouped[key] ?? UsageTotals()) + row.totals
        }
        return grouped.map { ($0.key, $0.value) }.sorted {
            let (a, b) = (value($0.totals, metric), value($1.totals, metric))
            return a != b ? a > b : $0.name < $1.name
        }
    }

    /// Every day of the current month, with future days marked so the chart can stop at today.
    public static func monthDays(_ daily: [UsageDay], now: Date = Date(), calendar: Calendar = .current) -> [(date: Date, day: String, totals: UsageTotals, future: Bool)] {
        let known = Dictionary(daily.map { ($0.day, $0.totals) }, uniquingKeysWith: { $1 })
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        guard let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        return range.map { day in
            let date = calendar.date(byAdding: .day, value: day - 1, to: start) ?? start
            let key = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, day)
            return (date, key, known[key] ?? UsageTotals(), day > (components.day ?? 0))
        }
    }
}
