import Foundation
import PrismKit

/// Writes request metadata to the shared `ai-usage-v1.sqlite` ledger shown in AI settings.
/// Never stores transcripts, audio, keys or response bodies.
struct UsageLedger: Sendable {
    static let fileName = "ai-usage-v1.sqlite"
    let url: URL

    struct Ticket: Sendable {
        let id: Int64
    }

    /// Inserts an `unconfirmed` row before the request is sent, so interrupted paid requests stay visible.
    func start(feature: String, provider: String, model: String) -> Ticket? {
        guard let database = try? open() else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard (try? database.run("INSERT INTO requests(started_at,feature,provider,model,status) VALUES (?,?,?,?,'unconfirmed')",
                                 [now, feature, provider, model])) != nil else { return nil }
        return Ticket(id: database.lastInsertRowID)
    }

    func finish(_ ticket: Ticket, usage: UsageMeasurement, status: String = "completed") {
        guard let database = try? open() else { return }
        _ = try? database.run("UPDATE requests SET status=?,input_tokens=?,output_tokens=?,cost_usd=?,cost_kind=? WHERE id=?",
                              [status, usage.inputTokens, usage.outputTokens, usage.costUSD, usage.costKind, ticket.id])
    }

    private func open() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: url)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS requests (
                id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, feature TEXT NOT NULL,
                provider TEXT NOT NULL, model TEXT NOT NULL, status TEXT NOT NULL,
                input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, cost_kind TEXT NOT NULL DEFAULT 'unknown'
            ); CREATE INDEX IF NOT EXISTS requests_started ON requests(started_at);
            """)
        return database
    }
}
