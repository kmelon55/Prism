import Foundation

/// The searchable shape of any palette result, independent of how the result is presented or run.
public struct SearchCandidate: Sendable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var section: String
    public var keywords: [String]
    public var searchAliases: [String]
    /// Frequency boost from a provider. Clamped so it can never cross a match tier.
    public var rankingBoost: Double
    public var favoriteOrder: Int?
    /// Calculator and URL results only exist for the exact query that produced them.
    public var matchedQuery: String?

    public init(
        id: String, title: String, subtitle: String = "", section: String = "",
        keywords: [String] = [], searchAliases: [String] = [], rankingBoost: Double = 0,
        favoriteOrder: Int? = nil, matchedQuery: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.section = section
        self.keywords = keywords
        self.searchAliases = searchAliases
        self.rankingBoost = rankingBoost
        self.favoriteOrder = favoriteOrder
        self.matchedQuery = matchedQuery
    }
}

public enum CommandSearch {
    public static func score(_ item: SearchCandidate, query rawQuery: String, aliases: [String] = []) -> Double? {
        let query = TextMatching.normalize(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        let boost = item.rankingBoost.isFinite ? min(72, max(0, item.rankingBoost)) : 0
        if let matchedQuery = item.matchedQuery {
            let matched = TextMatching.normalize(matchedQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            return !query.isEmpty && matched == query ? 7_000_000 + boost : nil
        }
        if query.isEmpty {
            if let favoriteOrder = item.favoriteOrder { return 1000 - Double(min(100, max(0, favoriteOrder))) }
            return boost
        }

        typealias Field = (value: String, exact: Double, prefix: Double, fuzzy: Double)
        var fields: [Field] = [(item.title, 6, 5, 3)]
        fields += uniqueAliases(item.searchAliases).map { ($0, 6, 5, 3) }
        fields += uniqueAliases(aliases).map { ($0, 8, 4, 2) }
        fields.append((item.subtitle, 1, 1, 1))
        fields.append((item.section, 1, 1, 1))
        fields += item.keywords.map { ($0, 1, 1, 1) }

        var best: Double?
        for field in fields {
            let value = TextMatching.normalize(field.value)
            guard !value.isEmpty, let candidate = TextMatching.subsequenceScore(query, value) else { continue }
            let tier = value == query ? field.exact : value.hasPrefix(query) ? field.prefix : field.fuzzy
            let weighted = tier * 1_000_000 + 10_000 + max(-10_000, min(candidate, 10_000))
            best = max(best ?? weighted, weighted)
        }
        guard let best else { return nil }
        return best + boost + (item.favoriteOrder != nil ? 20 : 0)
    }

    /// Ranks matching items by score, keeping the input order for ties.
    public static func rank<Item>(
        _ items: [Item], query: String, aliases: [String: [String]] = [:],
        candidate: (Item) -> SearchCandidate
    ) -> [Item] {
        items.enumerated()
            .compactMap { index, item -> (index: Int, item: Item, score: Double)? in
                let searchable = candidate(item)
                guard let score = score(searchable, query: query, aliases: aliases[searchable.id] ?? []) else { return nil }
                return (index, item, score)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }

    private static func uniqueAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for alias in aliases {
            let normalized = TextMatching.normalize(alias.trimmingCharacters(in: .whitespacesAndNewlines))
            if !normalized.isEmpty && seen.insert(normalized).inserted { unique.append(normalized) }
        }
        return unique
    }
}
