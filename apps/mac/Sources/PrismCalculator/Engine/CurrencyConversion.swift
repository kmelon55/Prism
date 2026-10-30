import Foundation

/// Explicit currency requests from `currency.ts`. Only the fixed ECB table is fetched; amounts, pairs and
/// queries never leave the device.
enum CurrencyConversion {
    struct Intent: Equatable, Sendable {
        let amount: Double
        let from: String
        let to: String
    }

    struct Answer: Equatable, Sendable {
        let intent: Intent
        /// Grouped amount such as `1,000`.
        let amountLabel: String
        /// Grouped result rounded to the destination's minor units, such as `128,000`.
        let formatted: String
        /// The displayed number without grouping; this is what Copy puts on the clipboard.
        let copyValue: String
        /// `1 USD = 1,280 KRW`, or "Same currency".
        let rate: String
        /// Rate date and source, marked when the cached table could not be refreshed.
        let source: String
        let stale: Bool

        var title: String { "\(amountLabel) \(intent.from) = \(formatted) \(intent.to)" }
    }

    static let codes = "AUD BRL CAD CHF CNY CZK DKK EUR GBP HKD HUF IDR ILS INR ISK JPY KRW MXN MYR NOK NZD PHP PLN RON SEK SGD THB TRY USD ZAR"
        .split(separator: " ").map(String.init)

    private static let aliases: [String: String] = {
        var table = Dictionary(uniqueKeysWithValues: codes.map { ($0.lowercased(), $0) })
        table.merge([
            "달러": "USD", "미국달러": "USD", "원": "KRW", "원화": "KRW", "엔": "JPY", "엔화": "JPY",
            "유로": "EUR", "위안": "CNY", "위안화": "CNY", "파운드": "GBP",
            "$": "USD", "₩": "KRW", "€": "EUR", "£": "GBP",
        ]) { current, _ in current }
        return table
    }()

    private static let token = aliases.keys
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        .map(NSRegularExpression.escapedPattern(for:))
        .joined(separator: "|")
    private static let number = #"[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,6})?"#
    private static let destination = #"(?:\s*(?:to|in|->|→|/|=)?\s*("# + token + #"))?"#
    private static let amountFirst = Pattern("^(\(number))\\s*(\(token))\(destination)$", caseInsensitive: true)
    private static let currencyFirst = Pattern("^(\(token))\\s*(\(number))\(destination)$", caseInsensitive: true)
    private static let pair = Pattern("^(\(token))\(destination)$", caseInsensitive: true)
    private static let rateSuffix = Pattern(#"\s*환율$"#)

    static func parse(_ query: String) -> [Intent] {
        if query.utf16.count > 128 || query.containsControlCharacter { return [] }
        let text = query.jsTrimmed.lowercased()
        if text == "환율" || text == "exchange rates" {
            return ["USD", "EUR", "JPY", "CNY"].map { Intent(amount: $0 == "JPY" ? 100 : 1, from: $0, to: "KRW") }
        }
        let expression = rateSuffix.replace(in: text) { _ in "" }.jsTrimmed
        let asksForRate = expression != text
        let amountText: String?
        let fromToken: String?
        let target: String?
        if let match = amountFirst.match(expression) {
            (amountText, fromToken, target) = (match[1], match[2], match[3])
        } else if let match = currencyFirst.match(expression) {
            (amountText, fromToken, target) = (match[2], match[1], match[3])
        } else if let match = pair.match(expression) {
            // A lone currency word ("try", "php", "달러") is a plain word, not a request. Unlike the Tauri
            // app, it needs a destination ("USD/KRW") or the 환율 suffix ("유로 환율") to answer.
            guard match[2] != nil || asksForRate else { return [] }
            (amountText, fromToken, target) = (nil, match[1], match[2])
        } else {
            return []
        }
        guard let fromToken, let from = aliases[fromToken],
              let amount = Double((amountText ?? "1").replacingOccurrences(of: ",", with: "")),
              amount.isFinite, amount.magnitude <= 1e12
        else { return [] }
        let to = target.flatMap { aliases[$0] } ?? (from == "KRW" ? "USD" : "KRW")
        return [Intent(amount: amount, from: from, to: to)]
    }

    /// ISO 4217 minor units, as `Intl.NumberFormat` reports them for these currencies.
    static func minorUnits(_ code: String) -> Int {
        ["JPY", "KRW", "ISK"].contains(code) ? 0 : 2
    }

    static func answer(_ intent: Intent, snapshot: RateSnapshot?) throws(AnswerError) -> Answer {
        let (amount, from, to) = (intent.amount, intent.from, intent.to)
        var result = amount
        var unitRate = 1.0
        if from != to {
            guard let fromRate = snapshot?.rates[from], let toRate = snapshot?.rates[to],
                  fromRate.isFinite, toRate.isFinite, fromRate > 0, toRate > 0
            else { throw AnswerError(localized("A reference rate for \(from)/\(to) is unavailable.")) }
            result = amount * toRate / fromRate
            unitRate = toRate / fromRate
        }
        guard result.isFinite else { throw AnswerError(localized("This amount is too large to convert.")) }
        let copyValue = NumberFormat.javaScriptFixed(result, digits: minorUnits(to))
        let source: String
        if from == to {
            source = localized("Same currency · no exchange rate needed")
        } else {
            let snapshot = snapshot!
            source = snapshot.stale
                ? localized("Cached · refresh unavailable · \(snapshot.date) · ECB / Frankfurter · Daily reference rate")
                : localized("\(snapshot.date) · ECB / Frankfurter · Daily reference rate")
        }
        return Answer(
            intent: intent,
            amountLabel: NumberFormat.label(amount),
            formatted: NumberFormat.groupDecimal(copyValue),
            copyValue: copyValue,
            rate: from == to ? localized("Same currency") : "1 \(from) = \(NumberFormat.label(unitRate)) \(to)",
            source: source,
            stale: from != to && snapshot?.stale == true
        )
    }
}
