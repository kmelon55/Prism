import Foundation

/// One inline answer, independent of how the palette presents it. Built by the pure functions below so
/// recognition and formatting can be tested without AppKit.
struct InstantAnswer: Equatable, Sendable {
    enum Kind: Sendable {
        case calculation, unit, currency, date, timeZone
        /// A recognized request that cannot be answered; shown without actions.
        case failure
    }

    /// The same row IDs as the Tauri app (`calculator:result`, `currency:USD:KRW`, ...).
    var id: String
    var kind: Kind
    var section: String
    /// The answer as displayed, with grouping and unit.
    var title: String
    /// The input as understood, such as `1,000 + 2,000` or `100 USD · 1 USD = 1,280 KRW`.
    var subtitle: String
    var accessory: String
    /// The plain value Return copies: no grouping and no unit, exactly as the Tauri app copied it.
    var copyValue: String
    /// `input = answer`, for Copy with Expression.
    var equation: String
    /// The grouped display value, offered separately when it differs from `copyValue`.
    var formattedValue: String?
    var copiedMessage: String
    /// The Tauri app's query correlation: an answer only exists for the exact query that produced it.
    var matchedQuery: String

    enum Presentation: Sendable { case row, card, cell }
    /// A card shows `input → output` large; cells follow a card with related answers.
    var presentation = Presentation.row
    var input = ""
    var inputDetail = ""
    var output = ""
    var outputDetail = ""

    func presented(_ presentation: Presentation, input: String = "", inputDetail: String = "",
                   output: String, outputDetail: String = "") -> InstantAnswer {
        var answer = self
        answer.presentation = presentation
        answer.input = input
        answer.inputDetail = inputDetail
        answer.output = output
        answer.outputDetail = outputDetail
        return answer
    }
}

enum InstantAnswers {
    static func failure(_ error: AnswerError, id: String, section: String, query: String) -> InstantAnswer {
        InstantAnswer(id: id, kind: .failure, section: section, title: error.message, subtitle: "", accessory: "",
                      copyValue: "", equation: "", copiedMessage: "", matchedQuery: query.jsTrimmed)
    }

    // MARK: Arithmetic

    private static let arithmeticCandidate = Pattern(#"^[0-9\s()+\-*/.,]+$"#)
    private static let arithmeticOperator = Pattern(#"[+\-*/]"#)

    /// `calculator.ts`: only digits, spaces, parentheses, `+ - * / . ,` and at least one operator.
    /// In Korean, a large result also gets its reading (`1억 2,345만`) as a copyable cell.
    static func calculation(_ query: String) -> [InstantAnswer] {
        guard !query.isEmpty, query.utf16.count <= Arithmetic.maxExpressionBytes else { return [] }
        let trimmed = query.jsTrimmed
        guard !trimmed.isEmpty, arithmeticCandidate.matches(trimmed), arithmeticOperator.matches(trimmed),
              let expression = NumberFormat.normalizeArithmeticExpression(trimmed),
              let result = try? Arithmetic.evaluate(expression)
        else { return number(trimmed).map { [$0] } ?? [] }
        let input = NumberFormat.groupExpression(expression)
        let value = NumberFormat.groupDecimal(result)
        let reading = KoreanNumber.isPreferred ? KoreanNumber.reading(result) : nil
        let answer = InstantAnswer(
            id: "calculator:result", kind: .calculation, section: localized("Calculator"),
            title: value, subtitle: input, accessory: reading ?? "",
            copyValue: result, equation: "\(input) = \(value)", formattedValue: value == result ? nil : value,
            copiedMessage: localized("Calculator result copied"), matchedQuery: trimmed)
        let shown = NumberFormat.groupExpression(expression.replacingOccurrences(of: " ", with: ""))
            .replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
            .replacingOccurrences(of: "+", with: " + ").replacingOccurrences(of: "-", with: " − ")
        var answers = [answer.presented(.card, input: shown.jsTrimmed, output: value, outputDetail: reading ?? "")]
        if let reading { answers.append(koreanReading(reading, of: value, query: trimmed)) }
        return answers
    }

    private static let plainNumber = Pattern(#"^[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?$"#)

    /// A number typed on its own, read in Korean: `123456789` → `1억 2,345만 6,789`. Korean only, from 10,000.
    static func number(_ query: String) -> InstantAnswer? {
        let trimmed = query.jsTrimmed
        guard KoreanNumber.isPreferred, trimmed.utf16.count <= 40, plainNumber.matches(trimmed),
              let plain = NumberFormat.ungroupDecimal(trimmed).map({ $0.hasPrefix("+") ? String($0.dropFirst()) : $0 }),
              // Phone and account numbers keep their leading zero; they are not amounts.
              !plain.hasPrefix("0") || plain.hasPrefix("0."),
              let reading = KoreanNumber.reading(plain)
        else { return nil }
        let grouped = NumberFormat.groupDecimal(plain)
        return InstantAnswer(
            id: "calculator:korean", kind: .calculation, section: localized("Calculator"),
            title: reading, subtitle: grouped, accessory: localized("Korean reading"),
            copyValue: reading, equation: "\(grouped) = \(reading)",
            copiedMessage: localized("Copied."), matchedQuery: trimmed)
            .presented(.card, input: grouped, output: reading, outputDetail: localized("Korean reading"))
    }

    private static func koreanReading(_ reading: String, of value: String, query: String) -> InstantAnswer {
        InstantAnswer(
            id: "calculator:korean", kind: .calculation, section: localized("Calculator"),
            title: reading, subtitle: value, accessory: localized("Korean reading"),
            copyValue: reading, equation: "\(value) = \(reading)",
            copiedMessage: localized("Copied."), matchedQuery: query)
            .presented(.cell, output: reading, outputDetail: localized("Korean reading"))
    }

    // MARK: Units

    /// The requested conversion as a card, then related units as cells.
    static func unit(_ query: String) -> [InstantAnswer] {
        let section = localized("Unit conversion")
        do {
            guard let conversions = try UnitConversion.conversions(query), let primary = conversions.first else { return [] }
            let matched = query.jsTrimmed
            let input = "\(NumberFormat.groupDecimal(primary.amount)) \(primary.from.label)"
            var answers = conversions.enumerated().map { index, conversion in
                let value = display(conversion.result)
                let output = "\(value) \(conversion.to.label)"
                let grouped = NumberFormat.groupDecimal(conversion.result)
                let answer = InstantAnswer(
                    id: index == 0 ? "units:result" : "units:\(conversion.to.label)", kind: .unit, section: section,
                    title: output, subtitle: input, accessory: conversion.from.family.localizedName,
                    copyValue: conversion.result, equation: "\(input) = \(output)",
                    formattedValue: grouped == conversion.result ? nil : grouped,
                    copiedMessage: localized("Conversion result copied"), matchedQuery: matched)
                return index == 0
                    ? answer.presented(.card, input: input, inputDetail: conversion.from.localizedName,
                                       output: output, outputDetail: conversion.to.localizedName)
                    : answer.presented(.cell, output: output, outputDetail: conversion.to.localizedName)
            }
            if primary.from.family == .length, ["mm", "cm", "m"].contains(primary.from.label),
               let height = UnitConversion.feetAndInches(meters: primary.base) {
                let inches = NumberFormat.javaScriptString(height.inches)
                let output = "\(height.feet) ft \(inches) in"
                let answer = InstantAnswer(
                    id: "units:ft-in", kind: .unit, section: section, title: output, subtitle: input,
                    accessory: primary.from.family.localizedName, copyValue: "\(height.feet)′ \(inches)″",
                    equation: "\(input) = \(output)", copiedMessage: localized("Conversion result copied"), matchedQuery: matched)
                answers.insert(answer.presented(.cell, output: output, outputDetail: localized("Feet and inches")), at: 1)
            }
            return answers
        } catch {
            return [failure(error, id: "units:error", section: section, query: query)]
        }
    }

    /// Six significant digits, grouped: enough to read at a glance. Copy keeps the full value.
    static func display(_ plain: String) -> String {
        guard let value = Double(plain), value.isFinite else { return NumberFormat.groupDecimal(plain) }
        return NumberFormat.groupDecimal(NumberFormat.javaScriptString(NumberFormat.rounded(value, significantDigits: 6)))
    }

    // MARK: Currency

    static var currencySection: String { localized("Currency") }

    static func currency(_ intent: CurrencyConversion.Intent, snapshot: RateSnapshot?, query: String) -> InstantAnswer {
        let id = "currency:\(intent.from):\(intent.to)"
        do {
            let answer = try CurrencyConversion.answer(intent, snapshot: snapshot)
            let output = "\(answer.formatted) \(intent.to)"
            let accessory: String
            if let snapshot, intent.from != intent.to {
                accessory = snapshot.stale ? localized("Cached · \(snapshot.date)") : "ECB · \(snapshot.date)"
            } else {
                accessory = ""
            }
            let reading = KoreanNumber.isPreferred ? KoreanNumber.reading(answer.copyValue, currency: intent.to) : nil
            let rate = intent.from == intent.to || intent.amount == 1 ? "" : answer.rate
            return InstantAnswer(
                id: id, kind: .currency, section: currencySection,
                title: output, subtitle: subtitle(answer), accessory: accessory,
                copyValue: answer.copyValue, equation: answer.title,
                formattedValue: answer.formatted == answer.copyValue ? nil : answer.formatted,
                copiedMessage: localized("Converted amount copied"), matchedQuery: query.jsTrimmed)
                .presented(.card, input: "\(answer.amountLabel) \(intent.from)", inputDetail: rate.isEmpty ? accessory : rate,
                           output: output, outputDetail: reading ?? (rate.isEmpty ? "" : accessory))
        } catch {
            return failure(error, id: id, section: currencySection, query: query)
        }
    }

    /// `100 USD · 1 USD = 1,280 KRW`; a one-unit amount is its own rate, so it is not repeated.
    private static func subtitle(_ answer: CurrencyConversion.Answer) -> String {
        let input = "\(answer.amountLabel) \(answer.intent.from)"
        return answer.intent.amount == 1 && answer.intent.from != answer.intent.to ? input : "\(input) · \(answer.rate)"
    }

    // MARK: Date and time

    static func dateTime(_ query: String) -> InstantAnswer? {
        let section = localized("Date and time")
        do {
            guard let calculation = try DateTimeCalculation.calculate(query) else { return nil }
            let input = query.jsTrimmed
            let isTimeZone = calculation.kind == .timezone
            // A conversion's input is long and already in the search field; the route says enough.
            return InstantAnswer(
                id: "datetime:result", kind: isTimeZone ? .timeZone : .date, section: section,
                title: calculation.result, subtitle: isTimeZone ? "" : input, accessory: calculation.summary,
                copyValue: calculation.result, equation: "\(input) = \(calculation.result)",
                copiedMessage: localized("Copied."), matchedQuery: input)
                .presented(.card, input: input, output: calculation.result, outputDetail: calculation.summary)
        } catch {
            return failure(error, id: "datetime:error", section: section, query: query)
        }
    }
}
