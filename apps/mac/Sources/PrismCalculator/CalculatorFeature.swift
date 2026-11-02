import AppKit
import PrismCore
import PrismKit
import SwiftUI

/// Calculator, unit, currency and date answers in the root search.
public enum CalculatorFeature {
    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let rates = CurrencyRates(file: context.paths.file(CurrencyRates.fileName))
        let items = AnswerItems(context: context)
        return FeatureContribution(providers: [
            AnswerProvider(id: "calculator", items: items) { query in InstantAnswers.calculation(query) },
            AnswerProvider(id: "units", items: items) { query in InstantAnswers.unit(query) },
            AnswerProvider(id: "datetime", items: items) { query in InstantAnswers.dateTime(query).map { [$0] } ?? [] },
            AnswerProvider(id: "currency", items: items) { query in await currencyAnswers(query, rates: rates) },
        ])
    }

    /// Requests the shared table only when a conversion needs one; a same-currency request never does.
    static func currencyAnswers(_ query: String, rates: CurrencyRates) async -> [InstantAnswer] {
        let intents = CurrencyConversion.parse(query)
        guard !intents.isEmpty else { return [] }
        var snapshot: RateSnapshot?
        if intents.contains(where: { $0.from != $0.to }) {
            do {
                snapshot = try await rates.load()
            } catch {
                return [InstantAnswers.failure(error, id: "currency:error", section: InstantAnswers.currencySection, query: query)]
            }
        }
        if Task.isCancelled { return [] }
        // The first conversion is the card; any others (환율) follow as cells.
        return intents.enumerated().map { index, intent in
            var answer = InstantAnswers.currency(intent, snapshot: snapshot, query: query)
            if index > 0, answer.presentation == .card { answer.presentation = .cell }
            return answer
        }
    }
}

/// One provider per answer kind, so the network-bound currency answer never delays the local ones.
@MainActor
final class AnswerProvider: PaletteProvider {
    let id: String
    private let items: AnswerItems
    private let answers: @Sendable (String) async -> [InstantAnswer]

    init(id: String, items: AnswerItems, answers: @escaping @Sendable (String) async -> [InstantAnswer]) {
        self.id = id
        self.items = items
        self.answers = answers
    }

    func results(for query: String) async -> [PaletteItem] {
        guard !query.jsTrimmed.isEmpty else { return [] }
        let answers = answers
        let found = await Task.detached(priority: .userInitiated) { await answers(query) }.value
        guard !Task.isCancelled else { return [] }
        return found.map(items.item)
    }
}

/// Builds palette rows and their actions for answers.
@MainActor
struct AnswerItems {
    let context: any PrismContext

    func item(_ answer: InstantAnswer) -> PaletteItem {
        PaletteItem(
            candidate: SearchCandidate(
                id: answer.id, title: answer.title, subtitle: answer.subtitle, section: answer.section,
                rankingBoost: 72, matchedQuery: answer.matchedQuery),
            icon: icon(answer.kind),
            accessory: answer.accessory,
            actions: answer.kind == .failure ? [] : actions(answer),
            style: style(answer)
        )
    }

    private func style(_ answer: InstantAnswer) -> PaletteRowStyle {
        let card = PaletteAnswer(input: answer.input, inputDetail: answer.inputDetail,
                                 output: answer.output, outputDetail: answer.outputDetail)
        switch answer.presentation {
        case .row: return .row
        case .card: return .answer(card)
        case .cell: return .answerCell(card)
        }
    }

    private func icon(_ kind: InstantAnswer.Kind) -> PaletteIcon {
        switch kind {
        case .calculation: .symbol("plus.forwardslash.minus", tint: .cyan)
        case .unit: .symbol("ruler", tint: .orange)
        case .currency: .symbol("banknote", tint: .mint)
        case .date: .symbol("calendar", tint: .red)
        case .timeZone: .symbol("globe", tint: .blue)
        case .failure: .symbol("exclamationmark.triangle.fill", tint: .yellow)
        }
    }

    private func actions(_ answer: InstantAnswer) -> [PaletteAction] {
        let context = context
        let copyTitle = answer.kind == .currency ? localized("Copy Amount") : localized("Copy Result")
        var actions = [
            PaletteAction(id: "copy-answer", title: copyTitle, systemImage: "doc.on.doc") {
                PasteService.copy(answer.copyValue)
                return .notify(answer.copiedMessage)
            },
            PaletteAction(id: "paste-answer", title: localized("Paste to Previous App"), systemImage: "doc.on.clipboard",
                          shortcut: .init(.return, modifiers: .command)) {
                await Self.paste(answer.copyValue, context: context)
            },
            PaletteAction(id: "copy-equation", title: localized("Copy with Expression"), systemImage: "equal.square",
                          shortcut: .init("c", modifiers: [.command, .shift])) {
                PasteService.copy(answer.equation)
                return .notify(localized("Copied to Clipboard"))
            },
        ]
        if let formatted = answer.formattedValue {
            actions.append(PaletteAction(id: "copy-formatted", title: localized("Copy Formatted Value"), systemImage: "textformat.123",
                                         shortcut: .init("c", modifiers: [.command, .option])) {
                PasteService.copy(formatted)
                return .notify(localized("Copied to Clipboard"))
            })
        }
        return actions
    }

    private static func paste(_ value: String, context: any PrismContext) async -> PaletteActionOutcome {
        context.hidePalette()
        do {
            try await PasteService.paste(value, into: context.previousApplication)
        } catch {
            context.showHUD(localized("Paste requires Accessibility access. Allow it in settings or use Copy."))
        }
        return .dismiss
    }
}
