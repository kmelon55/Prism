import PrismCore
import Testing

@Suite struct FrecencyTests {
    @Test func applicationIDsMatchTheTauriIndex() {
        // `application_id("/Applications/Safari.app")` in app_catalog.rs.
        #expect(Frecency.applicationID(path: "/Applications/Safari.app") == "2f4170706c69636174696f6e732f5361666172692e617070")
        #expect(Frecency.path(fromApplicationID: Frecency.applicationID(path: "/Applications/한글.app")) == "/Applications/한글.app")
        #expect(Frecency.path(fromApplicationID: "abc") == nil)
        #expect(Frecency.path(fromApplicationID: "zz") == nil)
    }

    @Test func bonusFavorsRecentAndFrequentRunsAndStaysBelowATier() {
        let now: Int64 = 10_000_000
        #expect(Frecency.bonus(count: 0, lastUsedAt: 0, now: now) == 0)
        #expect(Frecency.bonus(count: 1, lastUsedAt: now - 60, now: now) > Frecency.bonus(count: 1, lastUsedAt: now - 90_000, now: now))
        #expect(Frecency.bonus(count: 20, lastUsedAt: now - 90_000, now: now) > Frecency.bonus(count: 1, lastUsedAt: now - 90_000, now: now))
        #expect(Frecency.bonus(count: .max, lastUsedAt: now, now: now) == 72)
    }
}
