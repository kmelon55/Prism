import Testing
@testable import PrismCore

// Ported from packages/command-core/src/search.test.ts so both rankers agree during the migration.

private func item(_ id: String, _ title: String, keywords: [String] = []) -> SearchCandidate {
    SearchCandidate(id: id, title: title, section: "Commands", keywords: keywords)
}

private func ranked(_ items: [SearchCandidate], _ query: String, aliases: [String: [String]] = [:]) -> [String] {
    CommandSearch.rank(items, query: query, aliases: aliases) { $0 }.map(\.id)
}

@Test func ranksExactTitleBeforeKeywordMatch() {
    #expect(ranked([item("keyword", "Open workspace", keywords: ["focus"]), item("exact", "Focus")], "focus") == ["exact", "keyword"])
}

@Test func supportsCompactSubsequenceSearches() {
    #expect(ranked([item("prefs", "Open Preferences")], "opref") == ["prefs"])
}

@Test func boundsProviderBoostWithoutTurningNonMatchesIntoMatches() {
    var frequent = item("frequent", "Alpha")
    frequent.rankingBoost = 48
    #expect(ranked([item("regular", "Alpha"), frequent], "alpha") == ["frequent", "regular"])
    #expect(ranked([frequent], "beta").isEmpty)
}

@Test func matchesUserAliasForOnlyItsCommand() {
    #expect(ranked([item("browser", "Open Browser"), item("mail", "Open Mail")], "web", aliases: ["browser": ["web"]]) == ["browser"])
}

@Test func prioritizesExactUserAliasOverTitleAndKeyword() {
    let commands = [item("keyword", "Open Workspace", keywords: ["focus"]), item("alias", "Concentrate"), item("title", "Focus")]
    #expect(ranked(commands, "focus", aliases: ["alias": ["focus"]]) == ["alias", "title", "keyword"])
}

@Test func ignoresEmptyUserAliases() {
    #expect(ranked([item("browser", "Open Browser")], "unmatched", aliases: ["browser": ["", "   "]]).isEmpty)
}

@Test func deduplicatesNormalizedAliasesWithStableOrdering() {
    let commands = [item("first", "First"), item("second", "Second")]
    #expect(ranked(commands, "web", aliases: ["first": ["web", " WEB ", "web"], "second": ["web"]]) == ["first", "second"])
}

@Test func keepsExplicitResultsOnlyForTheirRecognizedQuery() {
    var calculation = item("calc", "8")
    calculation.matchedQuery = "(18 + 6) / 3"
    #expect(ranked([calculation], " (18 + 6) / 3 ") == ["calc"])
    #expect(ranked([calculation], "8").isEmpty)
    #expect(ranked([calculation], "").isEmpty)
}

@Test func preventsBoostsFromCrossingMatchTiers() {
    var frequent = item("prefix", "Calendar")
    frequent.rankingBoost = 1_000_000
    #expect(ranked([frequent, item("exact", "Cal"), item("alias", "Paper Notes")], "cal", aliases: ["alias": ["cal"]]) == ["alias", "exact", "prefix"])
}

@Test func normalizesComposedAndDecomposedHangul() {
    let command = item("ko", "한글 메모")
    #expect(ranked([command], "한글".decomposedStringWithCanonicalMapping) == ["ko"])
    #expect(ranked([command], "노트", aliases: ["ko": ["노트".decomposedStringWithCanonicalMapping]]) == ["ko"])
}

@Test func leadingConsonantsMatchSyllables() {
    #expect(ranked([item("talk", "카카오톡")], "ㅋㅋㅇㅌ") == ["talk"])
}

@Test func applicationAliasesFindKoreanNames() {
    let chrome = InstalledApplication(path: "/Applications/Google Chrome.app", name: "Google Chrome", fileName: "Google Chrome", bundleIdentifier: nil)
    let calculator = InstalledApplication(path: "/System/Applications/Calculator.app", name: "계산기", fileName: "Calculator", bundleIdentifier: nil)
    #expect(CommandSearch.rank([calculator, chrome], query: "크롬") { $0.searchCandidate }.map(\.fileName) == ["Google Chrome"])
    #expect(CommandSearch.rank([chrome, calculator], query: "calc") { $0.searchCandidate }.map(\.fileName) == ["Calculator"])
}
