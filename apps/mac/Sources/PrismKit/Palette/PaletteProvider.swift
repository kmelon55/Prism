import Foundation

public enum PaletteRanking: Sendable {
    /// Items are scored by `CommandSearch` against the query and dropped when they do not match.
    /// Query-specific answers (calculator, web search) set `SearchCandidate.matchedQuery` to rank first.
    case search
    /// Items already matched by an external engine (Spotlight). They follow the ranked results in provider order.
    case appended
}

/// A source of palette rows. Each provider publishes independently, so a slow source never blocks the others.
@MainActor
public protocol PaletteProvider: AnyObject, Sendable {
    var id: String { get }
    var ranking: PaletteRanking { get }
    /// Called on every query change, including the empty query. Return quickly; move slow work off the main
    /// actor. A newer query cancels the task, and results for an outdated query are discarded.
    func results(for query: String) async -> [PaletteItem]
}

public extension PaletteProvider {
    var ranking: PaletteRanking { .search }
}
