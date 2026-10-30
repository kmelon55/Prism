import Foundation

/// The conservative preference merge from `backup.ts`: appearance and language are replaced, aliases are only
/// added, and current aliases win on an ID or normalized-value collision or when 1,000 aliases exist.
enum SafePreferencesMerge {
    static let maxAliases = 1000
    static let maxBlur = 32.0
    static let defaultOpacity = 64.0
    static let defaultBlur = 12.0

    struct AliasReview: Equatable, Identifiable {
        enum Status: Equatable { case add, idConflict, valueConflict, capacity }
        var id: String
        var alias: String
        var status: Status
        var existingAlias: String?
    }

    /// `aliasKey` in `backup.ts`: NFKC, trimmed, lowercased.
    static func aliasKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Legacy backups may carry blur up to 240; only the current range is applied.
    static func normalizedBlur(_ value: Double) -> Double {
        value.isFinite ? min(maxBlur, max(0, value)).rounded() : defaultBlur
    }

    static func merge(current: SafePreferences, incoming: SafePreferences) throws -> SafePreferences {
        try incoming.validate()
        var aliases = current.commandAliases
        var values = Set(aliases.values.map(aliasKey))
        for (id, alias) in incoming.commandAliases.sorted(by: { $0.key < $1.key }) {
            if aliases.count >= maxAliases || aliases[id] != nil || values.contains(aliasKey(alias)) { continue }
            aliases[id] = alias
            values.insert(aliasKey(alias))
        }
        var merged = incoming
        merged.backgroundBlur = normalizedBlur(incoming.backgroundBlur)
        merged.commandAliases = aliases
        return merged
    }

    /// Explains every alias with the same policy as `merge`, in the order the merge applies them.
    static func reviewAliases(current: [String: String], incoming: SafePreferences) -> [AliasReview] {
        var aliases = current
        var values = Set(aliases.values.map(aliasKey))
        return incoming.commandAliases.sorted(by: { $0.key < $1.key }).map { id, alias in
            if let existing = aliases[id] { return AliasReview(id: id, alias: alias, status: .idConflict, existingAlias: existing) }
            if values.contains(aliasKey(alias)) { return AliasReview(id: id, alias: alias, status: .valueConflict) }
            if aliases.count >= maxAliases { return AliasReview(id: id, alias: alias, status: .capacity) }
            aliases[id] = alias
            values.insert(aliasKey(alias))
            return AliasReview(id: id, alias: alias, status: .add)
        }
    }
}
