import Foundation
import Testing
@testable import PrismBackup

/// Ports of `backup.test.ts`, plus the native preference stores.
@Suite struct PreferencesTests {
    @Test func acceptsLegacyBlurButClampsItWhenRestoring() throws {
        for blur in [0.0, 12, 32, 44, 240] {
            var incoming = Fixtures.preferences()
            incoming.backgroundBlur = blur
            #expect(try SafePreferencesMerge.merge(current: Fixtures.preferences(), incoming: incoming).backgroundBlur == min(32, blur))
        }
    }

    @Test func rejectsMalformedRangesUnknownLanguageAndPrototypeAliases() {
        let safe = Fixtures.preferences()
        var cases: [SafePreferences] = []
        var value = safe; value.language = "fr"; cases.append(value)
        value = safe; value.backgroundOpacity = 0; cases.append(value)
        value = safe; value.backgroundBlur = .nan; cases.append(value)
        value = safe; value.commandAliases = ["__proto__": "bad"]; cases.append(value)
        value = safe; value.commandAliases = ["app:one": String(repeating: "가", count: 81)]; cases.append(value)
        value = safe; value.commandAliases = ["app:one": "  "]; cases.append(value)
        for value in cases { #expect(throws: BackupError(BackupMessage.invalid)) { try value.validate() } }
    }

    @Test func conservativelyMergesAliases() throws {
        var incoming = Fixtures.preferences(aliases: ["prism:settings": "changed", "app:collision": "ＳＥＴＴＩＮＧＳ", "app:new": "새 앱"])
        incoming.theme = "light"
        incoming.language = "ko"
        let current = Fixtures.preferences()
        let next = try SafePreferencesMerge.merge(current: current, incoming: incoming)
        #expect(next.theme == "light")
        #expect(next.language == "ko")
        #expect(next.commandAliases == ["prism:settings": "settings", "app:new": "새 앱"])
        #expect(current.commandAliases == ["prism:settings": "settings"])
    }

    @Test func explainsAliasConflictsConsistentlyWithMerge() throws {
        let incoming = Fixtures.preferences(aliases: ["prism:settings": "changed", "app:collision": "ＳＥＴＴＩＮＧＳ", "app:new": "new", "app:other": "NEW"])
        let review = SafePreferencesMerge.reviewAliases(current: Fixtures.preferences().commandAliases, incoming: incoming)
        #expect(review.map(\.status) == [.valueConflict, .add, .valueConflict, .idConflict])
        #expect(review.last?.existingAlias == "settings")
        let merged = try SafePreferencesMerge.merge(current: Fixtures.preferences(), incoming: incoming)
        #expect(merged.commandAliases.count == 1 + review.filter { $0.status == .add }.count)

        let full = Fixtures.preferences(aliases: Dictionary(uniqueKeysWithValues: (0..<1000).map { ("app:\($0)", "alias\($0)") }))
        #expect(SafePreferencesMerge.reviewAliases(current: full.commandAliases, incoming: Fixtures.preferences(aliases: ["app:extra": "extra"]))
            .first?.status == .capacity)
        #expect(try SafePreferencesMerge.merge(current: full, incoming: incoming).commandAliases.count == 1000)
    }

    @Test @MainActor func nativePreferencesRoundTripThroughDefaultsAndAliasFile() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PrismBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativePreferences(defaults: defaults, domain: suite, aliases: CommandAliasStore(url: directory.appending(path: CommandAliasStore.fileName)))

        let initial = try store.current()
        #expect(initial == SafePreferences(language: "system", theme: "system", reduceMotion: false, backgroundOpacity: 64, backgroundBlur: 12,
                                           showApplicationIcons: true, commandAliases: [:]))
        var incoming = Fixtures.preferences(aliases: ["window:left-half": "왼쪽"])
        incoming.language = "ko"
        incoming.reduceMotion = true
        try store.restore(SafePreferencesMerge.merge(current: initial, incoming: incoming))
        #expect(defaults.string(forKey: "theme") == "dark")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ko"])
        let restored = try store.current()
        #expect(restored.language == "ko")
        #expect(restored.reduceMotion)
        #expect(restored.backgroundOpacity == 97)
        #expect(restored.backgroundBlur == 32)
        #expect(restored.commandAliases == ["window:left-half": "왼쪽"])

        incoming.language = "system"
        try store.restore(incoming)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    }

    @Test func malformedAliasFileIsNeverOverwritten() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: CommandAliasStore.fileName)
        let store = CommandAliasStore(url: url)
        #expect(try store.load().isEmpty)
        try store.save(["a:b": "c"])
        #expect(try store.load() == ["a:b": "c"])
        try Data("{broken".utf8).write(to: url)
        #expect(throws: BackupError(CommandAliasStore.malformed)) { try store.save([:]) }
        #expect(try Data(contentsOf: url) == Data("{broken".utf8))
    }
}
