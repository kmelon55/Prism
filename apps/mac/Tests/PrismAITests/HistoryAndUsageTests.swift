import Foundation
import PrismKit
import Testing
@testable import PrismAI

struct UsageTests {
    @Test func costsPreserveUnknownAndPreferReportedOverEstimates() {
        #expect(UsageMeasurement.measure([:], prices: nil).costUSD == nil)
        #expect(UsageMeasurement.measure(["usage": ["cost": "0.003", "prompt_tokens": 100, "completion_tokens": 20]], prices: (99, 99)).costUSD == 0.003)
        #expect(UsageMeasurement.measure(["usage": ["cost": 0]], prices: nil).costUSD == 0)
        let estimate = UsageMeasurement.measure(["usage": ["input_tokens": 1000, "output_tokens": 500]], prices: (1, 2))
        #expect(estimate.costUSD == 0.002 && estimate.costKind == "estimated")
        #expect(UsageMeasurement.measure(["usage": ["input_tokens": 1000]], prices: (1, 2)).costUSD == nil)
        #expect(UsageMeasurement.measure(["usage": ["cost": "NaN"]], prices: nil).costUSD == nil)
    }

    @Test func aggregatesAllRequestsByTupleAndDayBeyondTheRecentLimit() throws {
        let ledger = try UsageLedger(database: .inMemory())
        for _ in 0..<20 { _ = try ledger.insert(feature: "cleanup", provider: "vercel", model: "same") }
        _ = try ledger.insert(feature: "prompt", provider: "vercel", model: "same")
        _ = try ledger.insert(feature: "prompt", provider: "openai", model: "same")
        let summary = try ledger.summary(since: 0)
        #expect(summary.recent.count == 12)
        #expect(summary.month.requests == 22)
        #expect(summary.breakdown.count == 3)
        #expect(summary.breakdown.first { $0.feature == "cleanup" }?.totals.requests == 20)
        #expect(summary.daily.reduce(0) { $0 + $1.totals.requests } == 22)
        #expect(summary.daily.allSatisfy { $0.day.count == 10 })
    }

    @Test func ledgerSurvivesReopenAndDoesNotDoubleCountCompletion() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ai-usage-v1.sqlite")
        var ledger: UsageLedger? = try UsageLedger(url: url)
        let id = try ledger!.insert(feature: "cleanup", provider: "vercel", model: "fixture/model")
        _ = try ledger!.insert(feature: "transcription", provider: "custom", model: "fixture")
        let measurement = UsageMeasurement.measure(["usage": ["cost": 0.002, "input_tokens": 100, "output_tokens": 30]], prices: nil)
        try ledger!.update(id, measurement: measurement, status: "completed")
        try ledger!.update(id, measurement: measurement, status: "completed")
        ledger = nil
        let reopened = try UsageLedger(url: url)
        let summary = try reopened.summary(since: 0)
        #expect(summary.month.requests == 2 && summary.month.inputTokens == 100 && summary.month.unknownCostRequests == 1)
        #expect(summary.month.knownCostUSD == 0.002)
        #expect(try reopened.summary(since: UsageLedger.now).month.requests == 0)
        #expect(summary.recent.contains { $0.status == "unconfirmed" })
    }

    @Test func presentationGroupsAndFormatsLikeTheTauriView() {
        let rows = [
            UsageBreakdown(feature: "chat", provider: "vercel", model: "a", totals: UsageTotals(requests: 2, knownCostUSD: 0.5)),
            UsageBreakdown(feature: "chat", provider: "openai", model: "b", totals: UsageTotals(requests: 1, knownCostUSD: 1)),
            UsageBreakdown(feature: "cleanup", provider: "vercel", model: "a", totals: UsageTotals(requests: 1, knownCostUSD: 0.1, unknownCostRequests: 0, estimatedRequests: 1)),
        ]
        let byFeature = UsagePresentation.group(rows, by: .feature, metric: .cost)
        #expect(byFeature.map(\.name) == ["chat", "cleanup"])
        #expect(byFeature[0].totals.requests == 3)
        #expect(UsagePresentation.group(rows, by: .model, metric: .requests).first?.name == "vercel / a")
        #expect(UsagePresentation.cost(UsageTotals()) == "$0")
        #expect(UsagePresentation.cost(UsageTotals(requests: 2, unknownCostRequests: 2)) == "Cost unavailable")
        #expect(UsagePresentation.cost(UsageTotals(requests: 2, knownCostUSD: 0.25, unknownCostRequests: 1, estimatedRequests: 1)) == "≈ $0.25 + ?")
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 2, day: 10))!
        let days = UsagePresentation.monthDays([UsageDay(day: "2026-02-03", totals: UsageTotals(requests: 4))], now: now, calendar: calendar)
        #expect(days.count == 28 && days[2].totals.requests == 4 && !days[9].future && days[10].future)
    }
}

struct HistoryTests {
    let id = "12345678-1234-1234-1234-123456789012"

    func store() throws -> ChatHistoryStore { try ChatHistoryStore(database: .inMemory()) }

    @Test func persistsLongHistoryWithASeparateSummaryAndValidatesBoundaries() throws {
        let messages = (0..<120).map { ChatTurn(role: $0 % 2 == 0 ? "user" : "assistant", content: "Original message \($0)") }
        var session = ChatSession(id: id, selection: AISelection(provider: .openai, model: "fixture"), title: "Long conversation", messages: messages,
                                  compaction: ChatCompaction(summary: "Important decisions", through: 100), draft: "Continue")
        let store = try store()
        try store.save(session)
        let loaded = try store.load()
        #expect(loaded.count == 1 && loaded[0].messages.count == 120 && loaded[0].messages[0].content == "Original message 0")
        #expect(loaded[0].compaction?.through == 100)
        for through in [1, 121, 122] {
            session.compaction?.through = through
            #expect(throws: AIError.self) { try store.save(session) }
        }
        #expect(try store.load()[0].compaction?.through == 100)
    }

    @Test func readsTauriRowsIncludingLegacyTextSessionsAndDraftImages() throws {
        let database = try SQLiteDatabase.inMemory()
        let store = try ChatHistoryStore(database: database)
        let image = Fixture.image()
        let legacy = #"{"id":"\#(id)","provider":"compatible","model":"vision","title":"Capture","messages":[],"draft":"","updatedAt":0}"#
        try database.run("INSERT INTO conversations (id,updated_at,content) VALUES (?,?,?)", [id, 0, legacy])
        let loaded = try store.load()
        #expect(loaded.count == 1 && loaded[0].draftImage == nil && loaded[0].modelName == nil && !loaded[0].pinned)
        var session = loaded[0]
        session.draftImage = image
        try store.save(session)
        #expect(try store.load()[0].draftImage == image)
        session.draftImage = nil
        session.messages = [ChatTurn(role: "user", content: "Explain", image: image), ChatTurn(role: "assistant", content: "Answer")]
        try session.validate()
        session.messages[1].image = image
        #expect(throws: AIError.self) { try session.validate() }
    }

    @Test func storedJSONUsesTheTauriKeys() throws {
        let database = try SQLiteDatabase.inMemory()
        let store = try ChatHistoryStore(database: database)
        var session = ChatSession(id: id, selection: AISelection(provider: .vercel, model: "maker/chat"), title: "Question", draft: "Retry me")
        session.messages = [ChatTurn(role: "user", content: "Q"), ChatTurn(role: "assistant", content: "A", modelName: "Maker Chat")]
        try store.save(session)
        let text = try database.query("SELECT content FROM conversations") { $0.string("content") ?? "" }[0]
        let json = try JSON.parse(text)
        for key in ["id", "provider", "model", "title", "messages", "draft", "updatedAt", "pinned"] { #expect(json[key].hasValue, "\(key)") }
        #expect(json["modelName"].isNull && json["compaction"].isNull && json["draftImage"].isNull)
        #expect(json["messages"][1]["modelName"] == "Maker Chat" && json["messages"][0]["modelName"].isNull)
        #expect(json["provider"] == "vercel")
    }

    @Test func persistsTurnsAndDraftsWithoutOverwritingOtherSessions() throws {
        let store = try store()
        let session = ChatSession(id: id, selection: AISelection(provider: .vercel, model: "maker/chat"), title: "Question", draft: "Retry me")
        try store.save(session)
        var other = session
        other.id = "12345678-1234-1234-1234-123456789013"
        try store.save(other)
        var broken = session
        broken.messages = [ChatTurn(role: "assistant", content: "bad")]
        #expect(throws: AIError.self) { try store.save(broken) }
        let loaded = try store.load()
        #expect(loaded.count == 2 && loaded.first { $0.id == id }?.draft == "Retry me")
        try store.delete(other.id)
        #expect(try store.load().count == 1)
        #expect(throws: AIError.self) { try store.delete("not-a-uuid") }
    }

    @Test func limitsHistoryToOneHundredConversations() throws {
        let store = try store()
        for index in 0..<100 {
            try store.save(ChatSession(id: String(format: "12345678-1234-1234-1234-%012d", index), selection: AISelection(provider: .vercel, model: "m"), draft: "d"))
        }
        #expect(throws: AIError.self) { try store.save(ChatSession(selection: AISelection(provider: .vercel, model: "m"), draft: "d")) }
    }

    @Test func forksKeepTheSourceAndOnlyEarlierCheckpoints() throws {
        let image = Fixture.image()
        var session = ChatSession(id: id, selection: AISelection(provider: .vercel, model: "m"), title: "Plan", pinned: true)
        session.messages = [ChatTurn(role: "user", content: "One"), ChatTurn(role: "assistant", content: "A1"),
                            ChatTurn(role: "user", content: "Two", image: image), ChatTurn(role: "assistant", content: "A2")]
        session.compaction = ChatCompaction(summary: "S", through: 2)
        let fork = try session.fork(at: 2)
        #expect(fork.id != session.id && !fork.pinned && fork.title == "Plan · Rewrite")
        #expect(fork.messages.count == 2 && fork.draft == "Two" && fork.draftImage == image && fork.compaction?.through == 2)
        #expect(try session.fork(at: 0).compaction == nil)
        #expect(throws: AIError.self) { try session.fork(at: 1) }
        #expect(session.messages.count == 4)
    }

    @Test func markdownExportIncludesMessagesAndDraftWithoutCredentials() {
        var session = ChatSession(id: id, selection: AISelection(provider: .vercel, model: "maker/chat"), title: "Line\nBreak", draft: "Unsent")
        session.messages = [ChatTurn(role: "user", content: "Q"), ChatTurn(role: "assistant", content: "A", modelName: "Maker")]
        let text = session.markdown()
        #expect(text.hasPrefix("# Line Break\n\n## You\n\nQ\n\n## Maker\n\nA\n\n## Draft\n\nUnsent\n"))
        session.title = "a/b:c"
        #expect(session.exportFileName == "a_b_c.md")
    }

    @Test func sortsPinnedFirstAndSearchesBodies() {
        let a = ChatSession(id: id, selection: .empty, title: "Alpha", updatedAt: 3)
        var b = ChatSession(selection: .empty, title: "Beta", updatedAt: 1)
        b.pinned = true
        var c = ChatSession(selection: AISelection(provider: .vercel, model: "maker/gamma"), title: "Gamma", updatedAt: 2)
        c.messages = [ChatTurn(role: "user", content: "배포 일정"), ChatTurn(role: "assistant", content: "ok")]
        #expect(ChatSession.sorted([a, b, c]).map(\.title) == ["Beta", "Alpha", "Gamma"])
        #expect(c.matches("배포") && c.matches("GAMMA") && !a.matches("배포"))
        let untitled = ChatSession(selection: .empty, title: "새 대화", draft: "  draft text ")
        #expect(untitled.hasDefaultTitle && untitled.displayTitle == "draft text")
    }
}
