import Foundation
import SwiftUI
import Testing
@testable import PrismKit

@MainActor
struct PrismLanguageTests {
    @Test func savesAndRemovesTheAppOverride() throws {
        let name = "PrismLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PrismLanguage.current(defaults: defaults, domain: name) == .system)
        for language in [PrismLanguage.en, .ko, .en, .system] {
            PrismLanguage.set(language, defaults: defaults)
            #expect(PrismLanguage.current(defaults: defaults, domain: name) == language)
        }
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
    }

    @Test func explicitSelectionWinsOverSystemLanguageAndRegion() {
        #expect(PrismLanguage.resolve(.en, systemLanguages: ["ko-KR"]) == "en")
        #expect(PrismLanguage.resolve(.ko, systemLanguages: ["en-US"]) == "ko")
        #expect(PrismLanguage.resolve(.system, systemLanguages: ["en-KR", "ko-KR"]) == "en")
        #expect(PrismLanguage.resolve(.system, systemLanguages: ["ja-JP", "ko-KR", "en-US"]) == "ko")
        #expect(PrismLanguage.resolve(.system, systemLanguages: ["ja-JP"]) == "en")
    }

    @Test func switchesBundleLanguageWithoutRestarting() {
        for (language, expected) in [("en", "Record Hotkey"), ("ko", "단축키 기록"), ("en", "Record Hotkey")] {
            let bundle = PrismLanguage.bundle(.module, language: language)
            #expect(String(localized: "Record Hotkey", bundle: bundle) == expected)
        }
    }

    @Test func unknownLanguageFallsBackToEnglish() {
        let bundle = PrismLanguage.bundle(.module, language: "fr")
        #expect(String(localized: "Record Hotkey", bundle: bundle) == "Record Hotkey")
    }

    @Test func metadataIsTranslatedWhenReadRatherThanWhenRegistered() {
        var language = "en"
        func title() -> String {
            String(localized: "Record Hotkey", bundle: PrismLanguage.bundle(.module, language: language))
        }
        let pane = SettingsPane(id: "test", title: title(), systemImage: "keyboard", order: 0,
                                keywords: [title()]) { EmptyView() }
        let widget = NotchWidget(id: "test", title: title(), systemImage: "keyboard") { _ in EmptyView() }
        let screen = PaletteScreen(id: "test", title: title()) { EmptyView() }
        let transfer = SyncTransfer(id: "test", title: title(), read: { Data() }, validate: { _ in }, apply: { _, _ in })
        for (value, expected) in [("en", "Record Hotkey"), ("ko", "단축키 기록"), ("en", "Record Hotkey")] {
            language = value
            #expect(pane.title == expected)
            #expect(pane.keywords == [expected])
            #expect(widget.title == expected)
            #expect(screen.title == expected)
            #expect(transfer.title == expected)
        }
    }
}
