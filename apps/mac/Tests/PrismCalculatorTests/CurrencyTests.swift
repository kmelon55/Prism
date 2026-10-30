import Foundation
import Testing
@testable import PrismCalculator

// Ported from apps/desktop/src/providers/currency.test.ts and src-tauri/src/currency.rs.

private typealias Intent = CurrencyConversion.Intent
private let snapshot = RateSnapshot(date: "2026-09-04", fetchedAt: 1_788_652_800,
                                    rates: ["EUR": 1, "USD": 1.25, "KRW": 1600, "JPY": 200, "CNY": 8], stale: false)

@Test(arguments: ["100 USD to KRW", "100달러", "$100", "USD 100 KRW", "100 미국달러 원화", "100 usd in krw", "100 USD → KRW"])
func recognizesCurrencyIntent(query: String) {
    #expect(CurrencyConversion.parse(query) == [Intent(amount: 100, from: "USD", to: "KRW")])
}

@Test(arguments: [
    ("10,000엔 원화", 10000.0, "JPY", "KRW"), ("1,000원 to USD", 1000, "KRW", "USD"),
    ("유로 환율", 1, "EUR", "KRW"), ("USD/KRW", 1, "USD", "KRW"),
    ("0.25 USD to EUR", 0.25, "USD", "EUR"), ("-100달러", -100, "USD", "KRW"),
    ("1000원 달러", 1000, "KRW", "USD"), ("€5", 5, "EUR", "KRW"),
])
func parsesCurrencyIntent(query: String, amount: Double, from: String, to: String) {
    #expect(CurrencyConversion.parse(query) == [Intent(amount: amount, from: from, to: to)])
}

@Test(arguments: [
    "", "100", "settings", "dollars file", "100 XYZ", "100 BTC to USD", "1,00 USD", "100 USD xyz",
    "1e10 USD", "1000000000001 USD", "100 USD\n", "USD " + String(repeating: "x", count: 130),
    // A lone currency word is a plain word in the native app (see CurrencyConversion.parse).
    "php", "try", "달러", "eur",
])
func doesNotInterpretAsCurrency(query: String) {
    #expect(CurrencyConversion.parse(query).isEmpty)
}

@Test func providesAnExplicitKRWOverviewIncludingThe100JPYConvention() {
    #expect(CurrencyConversion.parse("환율") == [
        Intent(amount: 1, from: "USD", to: "KRW"), Intent(amount: 1, from: "EUR", to: "KRW"),
        Intent(amount: 100, from: "JPY", to: "KRW"), Intent(amount: 1, from: "CNY", to: "KRW"),
    ])
    #expect(CurrencyConversion.parse("Exchange Rates").count == 4)
}

@Test func calculatesCrossRatesAndCopiesExactlyTheDisplayedAmount() throws {
    let answer = try CurrencyConversion.answer(Intent(amount: 100, from: "USD", to: "KRW"), snapshot: snapshot)
    #expect(answer.title == "100 USD = 128,000 KRW")
    #expect(answer.copyValue == "128000")
    #expect(answer.source.contains("2026-09-04 · ECB / Frankfurter"))
    #expect(answer.rate == "1 USD = 1,280 KRW")
    let item = InstantAnswers.currency(Intent(amount: 100, from: "USD", to: "KRW"), snapshot: snapshot, query: " 100 USD to KRW ")
    #expect(item.id == "currency:USD:KRW")
    #expect(item.matchedQuery == "100 USD to KRW")
    #expect(item.title == "128,000 KRW")
    #expect(item.copyValue == "128000")
}

@Test func roundsToTheDestinationCurrencysMinorUnits() throws {
    let answer = try CurrencyConversion.answer(Intent(amount: 1000, from: "KRW", to: "USD"), snapshot: snapshot)
    #expect(answer.title == "1,000 KRW = 0.78 USD")
    #expect(answer.copyValue == "0.78")
}

@Test func labelsStaleCachedDataExplicitly() throws {
    var stale = snapshot
    stale.stale = true
    let answer = try CurrencyConversion.answer(Intent(amount: 1, from: "EUR", to: "USD"), snapshot: stale)
    #expect(answer.source.contains("Cached · refresh unavailable · 2026-09-04"))
    #expect(answer.stale)
}

@Test func sameCurrencyNeedsNoTable() async throws {
    let answer = try CurrencyConversion.answer(Intent(amount: 100, from: "USD", to: "USD"), snapshot: nil)
    #expect(answer.copyValue == "100.00")
    let rates = CurrencyRates(snapshot: nil, retryAfter: 0, fetch: { Issue.record("Unexpected fetch"); return Data() },
                              now: { 1_788_652_800 })
    #expect(await CalculatorFeature.currencyAnswers("paper", rates: rates).isEmpty)
    #expect(await CalculatorFeature.currencyAnswers("100 USD to USD", rates: rates).first?.copyValue == "100.00")
}

@Test func surfacesAMissingCurrencyOrNetworkFailureInsteadOfInventingARate() async {
    #expect(throws: AnswerError.self) { try CurrencyConversion.answer(Intent(amount: 1, from: "GBP", to: "KRW"), snapshot: snapshot) }
    let rates = CurrencyRates(snapshot: nil, retryAfter: 0, fetch: { throw URLError(.notConnectedToInternet) },
                              now: { 1_788_652_800 })
    let answers = await CalculatorFeature.currencyAnswers("100달러", rates: rates)
    #expect(answers.count == 1)
    #expect(answers.first?.kind == .failure)
    #expect(answers.first?.id == "currency:error")
}

// MARK: Rate table (currency.rs)

private let now: UInt64 = 1_788_652_800 // 2026-09-06 UTC
private let fixture = #"[{"date":"2026-09-04","base":"EUR","quote":"USD","rate":1.2},{"date":"2026-09-04","base":"EUR","quote":"KRW","rate":1600}]"#

@Test func acceptsADatedTableAndAddsTheBaseIdentity() throws {
    let parsed = try CurrencyRates.parse(Data(fixture.utf8), now: now)
    #expect(parsed.rates["EUR"] == 1)
    #expect(parsed.rates["KRW"] == 1600)
    #expect(!parsed.stale)
}

@Test func rejectsInvalidRatesBasesDatesAndDuplicates() {
    var invalid = [
        fixture.replacingOccurrences(of: "1.2", with: "0"),
        fixture.replacingOccurrences(of: "1.2", with: "-1"),
        fixture.replacingOccurrences(of: "1.2", with: "1e999"),
        fixture.replacingOccurrences(of: "EUR", with: "USD"),
        fixture.replacingOccurrences(of: "2026-09-04", with: "2026-02-30"),
        fixture.replacingOccurrences(of: "2026-09-04", with: "2026-09-07"),
        fixture.replacingOccurrences(of: "2026-09-04", with: "2025-09-04"),
        fixture.replacingOccurrences(of: "KRW", with: "USD"),
        fixture.replacingOccurrences(of: "USD", with: "usd"),
        "[]",
    ]
    if let range = fixture.range(of: "2026-09-04") {
        invalid.append(fixture.replacingCharacters(in: range, with: "2026-09-03"))
    }
    for table in invalid {
        #expect(throws: AnswerError.self, "\(table)") { try CurrencyRates.parse(Data(table.utf8), now: now) }
    }
    #expect(throws: AnswerError.self) { try CurrencyRates.parse(Data(repeating: 0x20, count: CurrencyRates.maxBytes + 1), now: now) }
}

@Test func diskCacheRoundTripsAndCannotExtendTheRateDate() throws {
    let parsed = try CurrencyRates.parse(Data(fixture.utf8), now: now)
    var restored = try JSONDecoder().decode(RateSnapshot.self, from: JSONEncoder().encode(parsed))
    #expect(CurrencyRates.isValid(restored, now: now + CurrencyRates.hour))
    #expect(!CurrencyRates.isValid(restored, now: now - 1))
    restored.fetchedAt = now + CurrencyRates.maxAge
    #expect(!CurrencyRates.isValid(restored, now: now + CurrencyRates.maxAge))
}

/// A mutable clock and request counter shared with the actor under test.
private final class Harness: @unchecked Sendable {
    var now: UInt64
    var requests = 0
    var response: Data?
    init(now: UInt64) { self.now = now }
}

private func table(date: String) -> Data {
    Data(#"[{"date":"\#(date)","base":"EUR","quote":"USD","rate":1.25},{"date":"\#(date)","base":"EUR","quote":"KRW","rate":1600}]"#.utf8)
}

@Test func freshCacheIsImmediateAndRefreshFailureIsExplicit() async throws {
    let harness = Harness(now: now)
    func rates(fetchedAt: UInt64) -> CurrencyRates {
        let cached = RateSnapshot(date: "2026-09-05", fetchedAt: fetchedAt, rates: ["EUR": 1, "USD": 1.2, "KRW": 1600], stale: false)
        return CurrencyRates(snapshot: cached, retryAfter: now + 60,
                             fetch: { harness.requests += 1; throw URLError(.timedOut) }, now: { harness.now })
    }
    #expect(try await !rates(fetchedAt: now).load().stale)
    // Older than an hour but inside the retry backoff: no request, the table is marked stale.
    #expect(try await rates(fetchedAt: now - 2 * CurrencyRates.hour).load().stale)
    await #expect(throws: AnswerError.self) { try await rates(fetchedAt: now - CurrencyRates.maxAge - 1).load() }
    #expect(harness.requests == 0)
}

@Test func failedRefreshBacksOffFifteenSecondsThenPersistsTheNewTable() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "prism-currency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: CurrencyRates.fileName)
    let harness = Harness(now: now)
    let rates = CurrencyRates(file: file, fetch: {
        harness.requests += 1
        guard let response = harness.response else { throw URLError(.notConnectedToInternet) }
        return response
    }, now: { harness.now })

    await #expect(throws: AnswerError.self) { try await rates.load() }
    await #expect(throws: AnswerError.self) { try await rates.load() }
    #expect(harness.requests == 1)

    harness.now += 15
    harness.response = table(date: "2026-09-04")
    #expect(try await rates.load().rates["KRW"] == 1600)
    #expect(harness.requests == 2)
    _ = try await rates.load()
    #expect(harness.requests == 2) // Reused for an hour.

    let stored = try JSONDecoder().decode(RateSnapshot.self, from: Data(contentsOf: file))
    #expect(stored.date == "2026-09-04")
    #expect(stored.fetchedAt == now + 15)

    // A fresh actor reads the disk cache without a request.
    let reopened = CurrencyRates(file: file, fetch: { harness.requests += 1; return Data() }, now: { harness.now })
    #expect(try await reopened.load().date == "2026-09-04")
    #expect(harness.requests == 2)
}
