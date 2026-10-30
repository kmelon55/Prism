import AppKit
import Testing
@testable import PrismLibrary

/// Ported from the `snippet_expansion.rs` tests.
@Suite struct SnippetExpansionTests {
    let snippets = [
        ExpansionSnippet(keyword: ";email", text: "안녕 👋\ne@example.com"),
        ExpansionSnippet(keyword: ";e", text: "short"),
    ]

    func matched(_ input: String) -> Int? {
        var matcher = SnippetMatcher()
        return input.compactMap { matcher.feed($0, snippets: snippets, safe: true) }.last
    }

    @Test func exactKeywordAndDelimiters() {
        for delimiter in [" ", "\t", "\n"] {
            #expect(matched(";email\(delimiter)") == 0)
        }
        #expect(matched(";e ") == 1)
        #expect(matched(";emails ") == nil)
        #expect(matched(";EMAIL ") == nil)
        #expect(matched(";email") == nil)
        #expect(matched("x;email ") == 0, "A keyword may follow other text, like the Rust matcher")
    }

    @Test func supportsAllCanonicalPrefixesAndInternalPunctuation() {
        for keyword in [";Email", "!email", "/email", ":email", ";a:!/;x"] {
            let items = [ExpansionSnippet(keyword: keyword, text: "value")]
            var matcher = SnippetMatcher()
            for key in keyword { #expect(matcher.feed(key, snippets: items, safe: true) == nil) }
            #expect(matcher.feed(" ", snippets: items, safe: true) == 0)
        }
    }

    @Test func unicodeAndCompositionResetCandidate() {
        #expect(matched(";ema한il ") == nil)
        #expect(matched(";ema\u{301}il ") == nil)
        #expect(matched(";ema👋il ") == nil)
        var matcher = SnippetMatcher()
        for character in ";email" { _ = matcher.feed(character, snippets: snippets, safe: true) }
        #expect(matcher.feed(" ", snippets: snippets, safe: false) == nil)
        #expect(matcher.feed(" ", snippets: snippets, safe: true) == nil)
    }

    @Test func allContextGuardsFailClosed() {
        let safe = ExpansionGuards()
        #expect(safe.isSafe)
        var cases: [ExpansionGuards] = []
        var guards = safe; guards.enabled = false; cases.append(guards)
        guards = safe; guards.permissions = false; cases.append(guards)
        guards = safe; guards.directInput = false; cases.append(guards)
        guards = safe; guards.secure = true; cases.append(guards)
        guards = safe; guards.excluded = true; cases.append(guards)
        guards = safe; guards.synthetic = true; cases.append(guards)
        guards = safe; guards.focusMatches = false; cases.append(guards)
        for unsafe in cases { #expect(!unsafe.isSafe) }
    }

    @Test func focusPasteOrRegistryResetPreventsSuffixExpansion() {
        var matcher = SnippetMatcher()
        for character in ";ema" { _ = matcher.feed(character, snippets: snippets, safe: true) }
        matcher.reset()
        for character in "il " { #expect(matcher.feed(character, snippets: snippets, safe: true) == nil) }
    }

    @Test func registryRejectsDuplicatesTemplatesAndNonSnippets() {
        func entry(_ id: String, _ keyword: String, _ value: String, _ kind: LibraryEntry.Kind) -> LibraryEntry {
            LibraryEntry(id: id, kind: kind, title: id, value: value, keyword: keyword)
        }
        let result = SnippetRegistry.build([
            entry("1", ";a", "a", .snippet),
            entry("2", ";a", "b", .snippet),
            entry("3", ";date", "{date}", .snippet),
            entry("4", ";url", "https://example.com", .link),
            entry("5", ";ok", "한국 👋", .snippet),
            entry("6", "bad", "x", .snippet),
        ])
        #expect(result == [ExpansionSnippet(keyword: ";ok", text: "한국 👋")])
    }

    @Test func configMatchesTauriFileAndValidatesExclusions() throws {
        let json = #"{"enabled":true,"excludedApps":["com.example.App"]}"#
        let config = try JSONDecoder().decode(SnippetExpansionConfig.self, from: Data(json.utf8))
        #expect(config.enabled)
        #expect(config.excludedApps == ["com.example.App"])
        #expect(config.isValid)
        #expect(config.excludes("com.example.App"))
        #expect(config.excludes("com.1password.1password"))
        #expect(config.excludes(nil))
        #expect(!config.excludes("com.apple.TextEdit"))
        #expect(!SnippetExpansionConfig(enabled: true, excludedApps: ["bad id"]).isValid)
        #expect(!SnippetExpansionConfig(enabled: true, excludedApps: Array(repeating: "a.b", count: 101)).isValid)
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(encoded.contains("\"excludedApps\""))
    }

    @MainActor
    @Test func pasteboardSnapshotRestoresEveryType() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.prism.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("dev.prism.test-type"))
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("snippet", forType: .string)
        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "original")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("dev.prism.test-type")) == Data([1, 2, 3]))
        #expect(pasteboard.types?.contains(SnippetExpander.transientTypeForTests) == true)
    }
}
