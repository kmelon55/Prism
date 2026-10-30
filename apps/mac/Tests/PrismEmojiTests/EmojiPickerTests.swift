import Foundation
import Testing
@testable import PrismEmoji

/// Ported from apps/desktop/src/emoji/EmojiPicker.test.tsx.
@MainActor
struct EmojiPickerTests {
    static let catalog: EmojiCatalog = try! EmojiCatalog.load(from: EmojiCatalog.bundledDataURL!)

    final class Recorder {
        var copied: [String] = []
        var pasted: [String] = []
        var copyError: (any Error)?
        var pasteErrors: [any Error] = []
        var canPaste = true
        var pasteGate: CheckedContinuation<Void, Never>?
        var holdPaste = false
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    let directory = FileManager.default.temporaryDirectory.appending(path: "prism-emoji-\(UUID().uuidString)")
    let recorder = Recorder()

    var recentsURL: URL { directory.appending(path: "emoji-recent-v1.json") }

    func makeModel(useKorean: Bool = false, loader: (() async -> EmojiCatalog?)? = nil) async -> EmojiPickerModel {
        let recorder = recorder
        let actions = EmojiActions(
            copy: { value in
                if let error = recorder.copyError { throw error }
                recorder.copied.append(value)
            },
            paste: { value in
                if recorder.holdPaste { await withCheckedContinuation { recorder.pasteGate = $0 } }
                if !recorder.pasteErrors.isEmpty { throw recorder.pasteErrors.removeFirst() }
                recorder.pasted.append(value)
            },
            canPaste: { recorder.canPaste }
        )
        let defaults = UserDefaults(suiteName: "prism-emoji-tests-\(UUID().uuidString)")!
        let model = EmojiPickerModel(
            actions: actions, recents: EmojiRecents(url: recentsURL), defaults: defaults, useKorean: useKorean,
            loader: loader ?? { Self.catalog }
        )
        await model.load()
        return model
    }

    func glyphs(_ model: EmojiPickerModel) -> [String] { model.items.map(\.emoji) }

    @Test func copiesExactVariationSelectorAndFamilyZWJSequences() async {
        let model = await makeModel()
        model.query = "❤️"
        #expect(glyphs(model) == ["\u{2764}\u{FE0F}"])
        await model.performCopy()
        #expect(recorder.copied.last == "\u{2764}\u{FE0F}")
        model.query = "👨‍👩‍👧‍👦"
        #expect(model.selectedItem?.name == "family: man, woman, girl, boy")
        await model.performCopy()
        #expect(recorder.copied.last == "👨\u{200D}👩\u{200D}👧\u{200D}👦")
        #expect(recorder.pasted.isEmpty)
    }

    @Test func searchesKoreanEnglishSlangAndCategoriesAcrossCategories() async {
        let model = await makeModel()
        model.query = "따봉"; #expect(glyphs(model).contains("👍"))
        model.query = "강아지"; #expect(glyphs(model).contains("🐶"))
        model.query = "laptop"; #expect(glyphs(model).contains("💻"))
        model.query = "음식"; #expect(glyphs(model).contains("🍊"))
        model.query = "ㅋㅋ"; #expect(glyphs(model).contains("😂"))
        model.query = "red heart"; #expect(glyphs(model).contains("❤️"))
        model.query = "nonexistent-emoji-xyz"; #expect(model.items.isEmpty)
    }

    @Test func decomposedKoreanQueryMatches() async {
        let model = await makeModel()
        model.query = "강아지".decomposedStringWithCanonicalMapping
        #expect(glyphs(model).contains("🐶"))
    }

    @Test func selectsOfficialSkinToneSequencesAndPersistsExactRecentsAfterPaste() async {
        let model = await makeModel()
        model.query = "woman technologist"
        model.tone = .medium
        #expect(glyphs(model).contains("👩🏽‍💻"))
        model.selection = glyphs(model).firstIndex(of: "👩🏽‍💻")!
        #expect(model.label(model.selectedItem!) == "woman technologist: medium skin tone")
        await model.performPrimary()
        #expect(recorder.pasted == ["👩🏽‍💻"])
        #expect(EmojiRecents(url: recentsURL).load().first == "👩🏽‍💻")

        let reopened = await makeModel()
        #expect(reopened.category == EmojiCategory.recent.id)
        #expect(glyphs(reopened) == ["👩🏽‍💻"])
    }

    @Test func boundsDeduplicatesAndFiltersUnknownRecents() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = ["invalid"] + Self.catalog.base.prefix(50).map(\.emoji)
        try JSONEncoder().encode(stored).write(to: recentsURL)
        let model = await makeModel()
        model.query = "👍"
        await model.performCopy()
        await model.performCopy()
        let saved = EmojiRecents(url: recentsURL).load()
        #expect(saved.count <= EmojiRecents.limit)
        #expect(saved.filter { $0 == "👍" }.count == 1)
        #expect(!saved.contains("invalid"))
        #expect(saved.first == "👍")
    }

    @Test func oversizedOrMalformedRecentsStartEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: recentsURL)
        #expect(EmojiRecents(url: recentsURL).load().isEmpty)
        try JSONEncoder().encode(Array(repeating: String(repeating: "x", count: 90), count: 400)).write(to: recentsURL)
        #expect(EmojiRecents(url: recentsURL).load().isEmpty)
        #expect(EmojiRecents.sanitize([String(repeating: "a", count: 101), "😀", "😀"]) == ["😀"])
    }

    @Test func gridArrowsMoveByColumnsAndReturnPastes() async {
        let model = await makeModel()
        #expect(model.category == EmojiCategory.groups[0].id)
        #expect(model.selectedItem?.emoji == "😀")
        #expect(model.move(.right))
        #expect(model.selectedItem?.emoji == "😃")
        #expect(model.move(.down))
        #expect(model.selection == 1 + EmojiPickerModel.columns)
        #expect(model.move(.up))
        #expect(model.move(.up))
        #expect(model.selection == 1)
        #expect(model.move(.left) && model.move(.left))
        #expect(model.selection == 0)
        #expect(!model.move(.submit))
        model.selection = 1
        await model.performPrimary()
        #expect(recorder.pasted == ["😃"])
    }

    @Test func downFromAboveAShorterLastRowLandsOnTheLastItem() async {
        let model = await makeModel()
        let count = model.items.count
        let lastRow = (count - 1) / EmojiPickerModel.columns
        model.selection = (lastRow - 1) * EmojiPickerModel.columns + EmojiPickerModel.columns - 1
        _ = model.move(.down)
        #expect(model.selection == min(count - 1, model.selection))
        let before = model.selection
        _ = model.move(.down)
        #expect(model.selection == before)
    }

    @Test func tabCyclesCategoriesAndLeavesSearch() async {
        let model = await makeModel()
        model.query = "heart"
        model.cycleCategory(by: 1)
        #expect(model.query.isEmpty)
        model.select(category: "Flags")
        model.cycleCategory(by: 1)
        #expect(model.category == EmojiCategory.recent.id)
        model.cycleCategory(by: -1)
        #expect(model.category == "Flags")
        #expect(model.items.allSatisfy { $0.group == "Flags" })
    }

    @Test func retainsFailedOperationAndRetriesTheExactEmojiWithoutRecordingFailures() async {
        recorder.pasteErrors = [Failure(errorDescription: "Target changed")]
        let model = await makeModel()
        model.query = "👍"
        await model.performPrimary()
        #expect(model.failure?.operation == .paste)
        #expect(model.failure?.detail == "Target changed")
        #expect(!FileManager.default.fileExists(atPath: recentsURL.path))
        // Return and Copy do nothing while the failure is shown; the selection may change.
        await model.performPrimary()
        await model.performCopy()
        model.query = "❤️"
        #expect(recorder.pasted.isEmpty && recorder.copied.isEmpty)
        await model.retry()
        #expect(recorder.pasted == ["👍"])
        #expect(model.failure == nil)
        #expect(EmojiRecents(url: recentsURL).load() == ["👍"])
    }

    @Test func offersCopyInsteadForTheExactFailedPasteString() async {
        recorder.pasteErrors = [Failure(errorDescription: "Accessibility permission is required.")]
        let model = await makeModel()
        model.query = "👩🏽‍💻"
        await model.performPrimary()
        #expect(model.failure?.detail == "Accessibility permission is required.")
        model.query = "❤️"
        await model.copyInstead()
        #expect(recorder.copied == ["👩🏽‍💻"])
        #expect(recorder.pasted.isEmpty)
        #expect(model.failure == nil)
    }

    @Test func pasteWithoutAccessibilityKeepsThePickerOpenWithoutPasting() async {
        recorder.canPaste = false
        let model = await makeModel()
        model.query = "👍"
        await model.performPrimary()
        #expect(model.failure?.needsAccessibility == true)
        #expect(recorder.pasted.isEmpty)
        await model.copyInstead()
        #expect(recorder.copied == ["👍"])
    }

    @Test func preventsDuplicatePendingActions() async {
        recorder.holdPaste = true
        let model = await makeModel()
        model.query = "👍"
        let first = Task { await model.performPrimary() }
        while recorder.pasteGate == nil { await Task.yield() }
        #expect(model.busy)
        await model.performPrimary()
        await model.performCopy()
        recorder.pasteGate?.resume()
        await first.value
        #expect(recorder.pasted == ["👍"])
        #expect(recorder.copied.isEmpty)
        #expect(model.status == "Pasted")
    }

    @Test func showsLoadFailureAndRetriesOnlyOnRequest() async {
        var attempts = 0
        var succeed = false
        let model = await makeModel(loader: {
            attempts += 1
            return succeed ? Self.catalog : nil
        })
        #expect(model.loadFailed)
        model.query = "heart"
        #expect(attempts == 1)
        succeed = true
        await model.load()
        #expect(!model.loadFailed)
        #expect(glyphs(model).contains("❤️"))
    }

    @Test func keepsActionSuccessSeparateFromAStorageFailure() async throws {
        // A file where the data directory should be makes every write fail.
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = await makeModel()
        model.query = "👍"
        await model.performCopy()
        #expect(recorder.copied == ["👍"])
        #expect(model.status == "Copied")
        #expect(model.storageFailed)
        #expect(model.failure == nil)
        #expect(model.recent == ["👍"])
    }

    @Test func koreanLabelsUseCLDRKoreanNames() async {
        let model = await makeModel(useKorean: true)
        model.query = "따봉"
        let thumbs = model.items.first { $0.emoji == "👍" }!
        #expect(model.label(thumbs) == "올린 엄지")
    }

    @Test func catalogKeepsOfficialCountsAndHomogeneousVariants() {
        #expect(Self.catalog.all.count == 3781)
        #expect(Self.catalog.base.allSatisfy { !$0.emoji.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } })
        let thumbs = Self.catalog.byEmoji["👍"]!
        #expect(Self.catalog.withSkinTone(thumbs, .dark).emoji == "👍🏿")
        #expect(Self.catalog.withSkinTone(Self.catalog.byEmoji["🐶"]!, .dark).emoji == "🐶")
    }
}
