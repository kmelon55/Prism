import Foundation
import Testing
@testable import PrismFiles

/// A temporary folder tree, removed when the fixture is released. Paths are canonical (`/private/var/...`).
final class Fixture {
    let root: String

    init() {
        let url = FileManager.default.temporaryDirectory.appending(path: "prism-files-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = FolderSnapshot.canonicalPath(url.path)!
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func write(_ relative: String) {
        let path = root + "/" + relative
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    }

    func mkdir(_ relative: String) {
        try! FileManager.default.createDirectory(atPath: root + "/" + relative, withIntermediateDirectories: true)
    }

    /// Forces a distinct directory modification time without sleeping.
    func touch(_ relative: String = "", offset: TimeInterval = 5) {
        let path = relative.isEmpty ? root : root + "/" + relative
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: path)
    }

    func names(_ hits: [FileHit]) -> [String] { hits.map(\.name) }
}

/// Ported from `library.rs` and `library/file_index.rs` tests.
struct FileIndexTests {
    @Test func searchKeyMatchesDecomposedKoreanNames() {
        #expect(FileSearchKey.make("작업 계획.md") == FileSearchKey.make("작업 계획.md".decomposedStringWithCanonicalMapping))
        #expect(FileSearchKey.make("ＲＥＡＤＭＥ") == "readme")
    }

    @Test func fileFiltersDistinguishDirectoriesAndExtensions() {
        #expect(FileTypeFilter.text.matches(name: "notes.MD", isDirectory: false))
        #expect(!FileTypeFilter.image.matches(name: "notes.MD", isDirectory: false))
        #expect(FileTypeFilter.image.matches(name: "photo.PNG", isDirectory: false))
        #expect(!FileTypeFilter.image.matches(name: "photo.PNG", isDirectory: true))
        #expect(FileTypeFilter.folder.matches(name: "photo.PNG", isDirectory: true))
        #expect(FileTypeFilter.document.matches(name: "plan.pdf", isDirectory: false))
        #expect(FileTypeFilter.all.matches(name: "x", isDirectory: true))
    }

    @Test func tokensSubsequencesAndKoreanHaveStableRankedPages() {
        let fixture = Fixture()
        for name in ["report-final.txt", "final annual report.txt", "r-e-p-o-r-t.txt", "문서 최종.txt"] { fixture.write(name) }
        let snapshot = FolderSnapshot.scan(roots: [fixture.root])
        #expect(snapshot.page(FilenameQuery("final report"), limit: 10).total == 2)
        #expect(snapshot.page(FilenameQuery("문서 최종"), limit: 10).total == 1)
        #expect(snapshot.page(FilenameQuery("rpt"), limit: 10).total == 2)
        let all = snapshot.page(FilenameQuery("report"), limit: 10).hits
        let paged = all.indices.map { snapshot.page(FilenameQuery("report"), offset: $0, limit: 1).hits[0].path }
        #expect(paged == all.map(\.path))
        #expect(FilenameQuery("a b c d e f g h i").rank("anything") == nil)
        #expect(FilenameQuery("rp").rank("report") == nil)
    }

    @Test func rankBucketsOrderExactPrefixSubstringTokensAndSubsequence() {
        let query = FilenameQuery("plan")
        #expect(query.rank("plan") == 0)
        #expect(query.rank("plan.md") == 1)
        #expect(query.rank("my plan.md") == 2)
        #expect(FilenameQuery("plan 2026").rank("2026 trip plan") == 3)
        #expect(FilenameQuery("pln").rank("plan") == 4)
        #expect(query.rank("other") == nil)
        #expect(FilenameQuery("계획").rank(FileSearchKey.make("여행 계획.txt".decomposedStringWithCanonicalMapping)) == 2)
    }

    @Test func queryOrderIsStableNormalizedFilteredAndPaginated() {
        let fixture = Fixture()
        for name in ["b-report.txt", "report-z.txt", "report-a.txt", "report.png", "문서.txt", "node_modules/hidden-report.txt"] {
            fixture.write(name)
        }
        let snapshot = FolderSnapshot.scan(roots: [fixture.root])
        let page = snapshot.page(FilenameQuery("report"), filter: .text, offset: 1, limit: 2)
        #expect(page.total == 3)
        #expect(fixture.names(page.hits) == ["report-z.txt", "b-report.txt"])
        #expect(snapshot.page(FilenameQuery("문서"), filter: .text, limit: 1).total == 1)
        #expect(snapshot.page(FilenameQuery("hidden"), limit: 1).total == 0)
    }

    @Test func excludesHiddenDependencyFoldersLinksAndAppBundleContents() throws {
        let fixture = Fixture()
        fixture.write(".secret/visible-name.txt")
        fixture.write("build/output.txt")
        fixture.write("Library/cache.txt")
        fixture.write("Tool.app/Contents/Info.plist")
        fixture.write("src/main.swift")
        try FileManager.default.createSymbolicLink(atPath: fixture.root + "/link.txt", withDestinationPath: fixture.root + "/src/main.swift")
        let snapshot = FolderSnapshot.scan(roots: [fixture.root])
        let names = Set(snapshot.files.map(\.name))
        #expect(names == ["Tool.app", "src", "main.swift"])
    }

    @Test func refreshReusesUnchangedDirectoriesAndDiscoversNewAndDeletedFiles() throws {
        let fixture = Fixture()
        fixture.mkdir("stable")
        fixture.write("stable/keep.txt")
        fixture.write("old.txt")
        let first = FolderSnapshot.scan(roots: [fixture.root])
        try FileManager.default.removeItem(atPath: fixture.root + "/old.txt")
        fixture.write("new.txt")
        fixture.touch()
        let next = FolderSnapshot.scan(roots: [fixture.root], previous: first)
        #expect(next.page(FilenameQuery("old"), limit: 10).total == 0)
        #expect(next.page(FilenameQuery("new"), filter: .text, limit: 10).total == 1)
        #expect(next.page(FilenameQuery("keep"), limit: 10).total == 1)
        // The unchanged folder's listing is reused without rereading it.
        #expect(next.directories[fixture.root + "/stable"]?.modified != nil)
        #expect(first.directories[fixture.root + "/stable"]?.entries.map(\.path) == next.directories[fixture.root + "/stable"]?.entries.map(\.path))
    }

    @Test func nestedChangesAreFoundOnTheNextRefresh() {
        let fixture = Fixture()
        fixture.write("a/b/c/deep.txt")
        let first = FolderSnapshot.scan(roots: [fixture.root])
        fixture.write("a/b/c/added.txt")
        fixture.touch("a/b/c")
        let next = FolderSnapshot.scan(roots: [fixture.root], previous: first)
        #expect(next.page(FilenameQuery("added"), limit: 10).total == 1)
    }

    @Test func flatDirectoryLimitPreservesCollectedRowsAndRetriesPartialListings() {
        let fixture = Fixture()
        for index in 0..<20 { fixture.write("file-\(index).txt") }
        let partial = FolderSnapshot.scan(roots: [fixture.root], maxFiles: 8)
        #expect(partial.limited)
        #expect(!partial.files.isEmpty && partial.files.count <= 8)
        #expect(partial.directories[fixture.root]?.modified == nil)
        let complete = FolderSnapshot.scan(roots: [fixture.root], previous: partial)
        #expect(!complete.limited)
        #expect(complete.files.count == 20)
    }

    @Test func expiredBudgetDoesNotReadDirectoryContents() {
        let fixture = Fixture()
        fixture.write("a.txt")
        let snapshot = FolderSnapshot.scan(roots: [fixture.root], budget: .zero)
        #expect(snapshot.limited)
        #expect(snapshot.files.isEmpty)
    }

    @Test func replacedRootAndCancelledWalkDoNotReturnFiles() throws {
        let fixture = Fixture()
        fixture.write("real/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: fixture.root + "/alias", withDestinationPath: fixture.root + "/real")
        let linked = FolderSnapshot.scan(roots: [fixture.root + "/alias"])
        #expect(linked.files.isEmpty && linked.limited)
        let cancelled = FolderSnapshot.scan(roots: [fixture.root], isCancelled: { true })
        #expect(cancelled.files.isEmpty)
        let missing = FolderSnapshot.scan(roots: [fixture.root + "/missing"])
        #expect(missing.files.isEmpty && missing.limited)
    }

    @Test func depthIsBoundedToSixteenLevels() {
        let fixture = Fixture()
        fixture.write((1...18).map { "d\($0)" }.joined(separator: "/") + "/bottom.txt")
        let snapshot = FolderSnapshot.scan(roots: [fixture.root])
        #expect(snapshot.limited)
        #expect(snapshot.page(FilenameQuery("bottom"), limit: 1).total == 0)
        #expect(snapshot.page(FilenameQuery("d16"), limit: 1).total == 1)
    }

    @Test func mergeDeduplicatesByPathRanksAndPrefersRecentlyUsed() {
        let query = FilenameQuery("plan")
        let local = [FileHit(path: "/a/my plan.txt", isDirectory: false), FileHit(path: "/a/plan.txt", isDirectory: false)]
        let spotlight = [
            FileHit(path: "/a/plan.txt", isDirectory: false, lastUsed: .now),
            FileHit(path: "/b/plan-old.txt", isDirectory: false, lastUsed: .distantPast),
            FileHit(path: "/b/plan-new.txt", isDirectory: false, lastUsed: .now),
            FileHit(path: "/b/unrelated.txt", isDirectory: false),
            FileHit(path: "/b/plans", isDirectory: true),
        ]
        let merged = FileRanking.merge([local, spotlight], query: query, filter: .text, limit: 10)
        #expect(merged.hits.map(\.path) == ["/b/plan-new.txt", "/b/plan-old.txt", "/a/plan.txt", "/a/my plan.txt"])
        #expect(merged.total == 4)
        #expect(FileRanking.merge([local, spotlight], query: query, filter: .all, limit: 2).total == 5)
    }

    @Test func displayLocationAbbreviatesTheHomeFolder() {
        #expect(FileHit.abbreviate("/Users/me/Documents", home: "/Users/me") == "~/Documents")
        #expect(FileHit.abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(FileHit.abbreviate("/Users/meow", home: "/Users/me") == "/Users/meow")
    }
}
