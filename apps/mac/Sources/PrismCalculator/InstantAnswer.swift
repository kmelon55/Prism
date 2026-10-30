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
    static func calculation(_ query: String) -> InstantAnswer? {
        guard !query.isEmpty, query.utf16.count <= Arithmetic.maxExpressionBytes else { return nil }
        let trimmed = query.jsTrimmed
        guard !trimmed.isEmpty, arithmeticCandidate.matches(trimmed), arithmeticOperator.matches(trimmed),
              let expression = NumberFormat.normalizeArithmeticExpression(trimmed),
              let result = try? Arithmetic.evaluate(expression)
        else { return nil }
        let input = NumberFormat.groupExpression(expression)
        let value = NumberFormat.groupDecimal(result)
        return InstantAnswer(
            id: "calculator:result", kind: .calculation, section: localized("Calculator"),
            title: value, subtitle: input, accessory: "",
            copyValue: result, equation: "\(input) = \(value)", formattedValue: value == result ? nil : value,
            copiedMessage: localized("Calculator result copied"), matchedQuery: trimmed)
    }

    // MARK: Units

    static func unit(_ query: String) -> InstantAnswer? {
        let section = localized("Unit conversion")
        do {
            guard let conversion = try UnitConversion.convert(query) else { return nil }
            let value = NumberFormat.groupDecimal(conversion.result)
            let input = "\(NumberFormat.groupDecimal(conversion.amount)) \(conversion.from.label)"
            let output = "\(value) \(conversion.to.label)"
            return InstantAnswer(
                id: "units:result", kind: .unit, section: section,
                title: output, subtitle: input, accessory: conversion.from.family.localizedName,
                copyValue: conversion.result, equation: "\(input) = \(output)",
                formattedValue: value == conversion.result ? nil : value,
                copiedMessage: localized("Conversion result copied"), matchedQuery: query.jsTrimmed)
        } catch {
            return failure(error, id: "units:error", section: section, query: query)
        }
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
            return InstantAnswer(
                id: id, kind: .currency, section: currencySection,
                title: output, subtitle: subtitle(answer), accessory: accessory,
                copyValue: answer.copyValue, equation: answer.title,
                formattedValue: answer.formatted == answer.copyValue ? nil : answer.formatted,
                copiedMessage: localized("Converted amount copied"), matchedQuery: query.jsTrimmed)
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
        } catch {
            return failure(error, id: "datetime:error", section: section, query: query)
        }
    }
}
