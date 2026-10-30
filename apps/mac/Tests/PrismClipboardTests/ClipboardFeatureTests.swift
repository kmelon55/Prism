import AppKit
import PrismKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PrismClipboard

// Images, pasteboard capture and paste guards. Pasteboard tests use private named pasteboards and never
// read or write the system clipboard.

func encode(_ image: CGImage, as type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

func image(width: Int, height: Int, rgba: [UInt8] = [23, 97, 201, 255]) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) { pixels.replaceSubrange(index..<(index + 4), with: rgba) }
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let board = NSPasteboard(name: NSPasteboard.Name("dev.prism.clipboard.tests.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    try body(board)
}

@Test func imageBoundsRejectZeroOversizePixelsBytesAndUnknownFormats() {
    #expect(!ClipboardPolicy.validDimensions(width: 0, height: 100))
    #expect(!ClipboardPolicy.validDimensions(width: ClipboardLimits.maxImageDimension + 1, height: 1))
    #expect(!ClipboardPolicy.validDimensions(width: 8192, height: 8192))
    #expect(ClipboardPolicy.validDimensions(width: 4000, height: 4000))
    #expect(throws: ClipboardError.self) {
        try StoredPayload(.image(Data(count: ClipboardLimits.maxImageBytes + 1), mimeType: "image/png", width: 1, height: 1))
    }
    #expect(throws: ClipboardError.self) { try StoredPayload(.image(Data([0]), mimeType: "image/tiff", width: 1, height: 1)) }
}

@Test func tiffCaptureNormalizesToPNGAndKeepsPixels() throws {
    let original = image(width: 4, height: 3)
    let payload = try ClipboardImages.payload(bytes: encode(original, as: .tiff), mimeType: "image/tiff")
    guard case .image(let bytes, let mimeType, let width, let height) = payload else { Issue.record("Expected image"); return }
    #expect(width == 4 && height == 3)
    #expect(mimeType == "image/png")
    let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
    #expect(decoded.width == 4 && decoded.height == 3)
    _ = try StoredPayload(payload)
    #expect(throws: ClipboardError.self) { try ClipboardImages.payload(bytes: Data([1, 2, 3]), mimeType: "image/tiff") }
    #expect(ClipboardImages.inputLimit(mimeType: "image/png") == ClipboardLimits.maxImageBytes)
    #expect(ClipboardImages.inputLimit(mimeType: "image/tiff") == ClipboardLimits.maxTIFFInputBytes)
}

@Test func originalImagesSurviveRestartDeduplicateAndAreRemovedWithHistory() throws {
    let bytes = encode(image(width: 2, height: 3), as: .png)
    #expect(throws: ClipboardError.self) { try ClipboardImages.payload(bytes: Data([1, 2, 3]), mimeType: "image/png") }
    let file = TemporaryDatabase()
    let id: Int64
    do {
        let store = ClipboardStore.open(url: file.url)
        try store.record(ClipboardImages.payload(bytes: bytes, mimeType: "image/png"))
        #expect(store.settings().entryCount == 0)
        try store.setEnabled(true)
        try store.record(ClipboardImages.payload(bytes: bytes, mimeType: "image/png"))
        id = try store.search("", limit: 1, kind: .image)[0].id
        try store.setPinned(id: id, pinned: true)
        try store.record(ClipboardImages.payload(bytes: bytes, mimeType: "image/png"))
        #expect(store.settings().entryCount == 1)
    }
    let store = ClipboardStore.open(url: file.url)
    #expect(try store.payload(id: id) == .image(bytes, mimeType: "image/png", width: 2, height: 3))
    let entry = try store.search("", limit: 1, kind: .image)[0]
    #expect(entry.pinned)
    #expect(entry.text == "PNG image · 2 × 3")
    try store.clear()
    #expect(throws: ClipboardError.self) { try store.payload(id: id) }
    #expect(try store.testScalar("SELECT COALESCE(SUM(length(payload)),0) FROM clipboard_entries") == 0)
}

@Test func selectedPreviewIsBoundedAndDoesNotChangeTheOriginal() throws {
    let store = try makeStore()
    let bytes = encode(image(width: 1024, height: 512), as: .png)
    try store.record(ClipboardImages.payload(bytes: bytes, mimeType: "image/png"))
    let id = try store.search("", limit: 1)[0].id
    let thumbnail = try store.thumbnail(id: id, maxPixelSize: 256)
    #expect(thumbnail.width == 256 && thumbnail.height == 128)
    #expect(try store.payload(id: id) == .image(bytes, mimeType: "image/png", width: 1024, height: 512))
    try store.record(text: "plain text")
    let textID = try store.search("plain", limit: 1)[0].id
    #expect(throws: ClipboardError.self) { try store.thumbnail(id: textID, maxPixelSize: 256) }
}

@Test func unchangedWriteRevisionPostsOnceAfterReadingTheCurrentRevision() {
    var order: [String] = []
    let result = ClipboardHistory.pasteIfRevisionMatches(42, current: { order.append("read"); return 42 }) {
        order.append("post")
        return .success(())
    }
    #expect((try? result.get()) != nil)
    #expect(order == ["read", "post"])
}

@Test func clipboardReplacedDuringActivationNeverPosts() {
    let result = ClipboardHistory.pasteIfRevisionMatches(42, current: { 43 }) {
        Issue.record("must not paste unrelated clipboard content")
        return .success(())
    }
    guard case .failure(let error) = result else { Issue.record("Expected failure"); return }
    #expect(error.message.contains("clipboard changed"))
}

@Test func postingErrorIsReturnedWithoutRetry() {
    var posts = 0
    let result = ClipboardHistory.pasteIfRevisionMatches(42, current: { 42 }) {
        posts += 1
        return .failure(ClipboardError("post failed"))
    }
    guard case .failure(let error) = result else { Issue.record("Expected failure"); return }
    #expect(error.message == "post failed")
    #expect(posts == 1)
}

@Test func pasteboardBaselinesFirstThenCapturesNewText() throws {
    try withPasteboard { board in
        board.clearContents()
        board.setString("before opt-in", forType: .string)
        let baseline = try #require(PasteboardIO.observe(board, previous: nil, preferences: ClipboardPreferences()) { "com.example" })
        #expect(try baseline.result.get() == nil)
        board.clearContents()
        board.setString("새 복사", forType: .string)
        let next = try #require(PasteboardIO.observe(board, previous: baseline.revision, preferences: ClipboardPreferences()) { "com.example" })
        #expect(try next.result.get() == .text("새 복사"))
        let unchanged = try #require(PasteboardIO.observe(board, previous: next.revision, preferences: ClipboardPreferences()) { "com.example" })
        #expect(try unchanged.result.get() == nil)
    }
}

@Test func pasteboardSkipsConcealedItemsAndExcludedApps() throws {
    try withPasteboard { board in
        let start = board.changeCount
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents()
        board.writeObjects([item])
        let concealed = try #require(PasteboardIO.observe(board, previous: start, preferences: ClipboardPreferences()) { nil })
        #expect(try concealed.result.get() == nil)

        board.clearContents()
        board.setString("from a password app", forType: .string)
        var preferences = ClipboardPreferences()
        preferences.excludedApplications = [ExcludedApplication(id: "com.example.vault", name: "Vault")]
        let excluded = try #require(PasteboardIO.observe(board, previous: start, preferences: preferences) { "com.example.vault" })
        #expect(try excluded.result.get() == nil)
        let allowed = try #require(PasteboardIO.observe(board, previous: start, preferences: preferences) { "com.example.editor" })
        #expect(try allowed.result.get() == .text("from a password app"))
    }
}

@Test func pasteboardRejectsMixedItemsAndUnsupportedFormats() throws {
    try withPasteboard { board in
        let start = board.changeCount
        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        let second = NSPasteboardItem()
        second.setString("two", forType: .string)
        board.clearContents()
        board.writeObjects([first, second])
        let mixed = try #require(PasteboardIO.observe(board, previous: start, preferences: ClipboardPreferences()) { nil })
        #expect(throws: ClipboardError.self) { try mixed.result.get() }

        board.clearContents()
        // HTML without a plain-text representation is skipped with a notice.
        board.setString("<b>bold</b>", forType: .html)
        let html = try #require(PasteboardIO.observe(board, previous: start, preferences: ClipboardPreferences()) { nil })
        #expect(throws: ClipboardError.unsupported) { try html.result.get() }
    }
}

@Test func writtenPayloadsRoundTripThroughCapture() throws {
    let directory = TemporaryDatabase()
    try FileManager.default.createDirectory(at: directory.directory, withIntermediateDirectories: true)
    let a = directory.directory.appending(path: "a.txt")
    let b = directory.directory.appending(path: "b.txt")
    try Data().write(to: a)
    try Data().write(to: b)
    let png = encode(image(width: 3, height: 2), as: .png)
    let payloads: [ClipboardPayload] = [
        .text("Line one\nline two"),
        .image(png, mimeType: "image/png", width: 3, height: 2),
        .files([a.absoluteString, b.absoluteString]),
    ]
    try withPasteboard { board in
        for payload in payloads {
            let before = board.changeCount
            let revision = try PasteboardIO.write(payload, to: board)
            #expect(revision == board.changeCount)
            let observed = try #require(PasteboardIO.observe(board, previous: before, preferences: ClipboardPreferences()) { nil })
            #expect(try observed.result.get() == payload)
        }
    }
}

@Test func presentationRecognizesLinksColorsAndFiles() {
    func entry(_ text: String, kind: ClipboardKind = .text, files: Int = 0) -> ClipboardEntry {
        ClipboardEntry(id: 1, text: text, capturedAtMs: 0, pinned: false, kind: kind, mimeType: nil, byteSize: 0, width: nil, height: nil, fileCount: files)
    }
    #expect(EntryPresentation(entry: entry("https://prism.dev/docs")).style == .link(URL(string: "https://prism.dev/docs")!))
    #expect(EntryPresentation(entry: entry("see https://prism.dev")).style == .text)
    #expect(EntryPresentation.color("#ff8800") != nil)
    #expect(EntryPresentation.color("#f80") != nil)
    #expect(EntryPresentation.color("#ff88") == nil)
    #expect(EntryPresentation.color("ff8800") == nil)
    #expect(EntryPresentation(entry: entry("\n\n  first   line  \nsecond")).title == "first line")
    #expect(EntryPresentation(entry: entry("/tmp/a.txt", kind: .files, files: 1)).title == "a.txt")
    #expect(EntryPresentation(entry: entry("/tmp/a.txt\n/tmp/b.txt", kind: .files, files: 2)).title.hasPrefix("a.txt"))
}

@MainActor
@Test func historySectionsPutPinsFirstThenGroupByDay() {
    let now = Date()
    let calendar = Calendar.current
    func entry(_ id: Int64, pinned: Bool = false, daysAgo: Int) -> ClipboardEntry {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return ClipboardEntry(id: id, text: "\(id)", capturedAtMs: Int64(date.timeIntervalSince1970 * 1000), pinned: pinned,
                              kind: .text, mimeType: nil, byteSize: 0, width: nil, height: nil, fileCount: 0)
    }
    let sections = ClipboardHistoryModel.group(
        [entry(1, pinned: true, daysAgo: 9), entry(2, daysAgo: 0), entry(3, daysAgo: 0), entry(4, daysAgo: 1), entry(5, daysAgo: 4)], now: now
    )
    #expect(sections.map { $0.entries.map(\.id) } == [[1], [2, 3], [4], [5]])
}

@MainActor
@Test func featureContributesTauriCommandIDsAndTheClipboardPane() async throws {
    let file = TemporaryDatabase()
    // The shell's context lives for the whole app; features hold it weakly.
    let context = FixtureContext(paths: AppPaths(dataDirectory: file.directory))
    let contribution = ClipboardFeature.make(context: context)
    #expect(contribution.settingsPanes.map(\.id) == ["clipboard"])
    #expect(contribution.settingsPanes.first?.group == .privacy)
    let items = await contribution.providers[0].results(for: "")
    #expect(items.map(\.id) == [ClipboardFeature.openHistoryCommandID, ClipboardFeature.clearHistoryCommandID])
    #expect(ClipboardFeature.openHistoryCommandID == "clipboard:open-history")
    guard case .push(let screen) = await items[0].actions[0].run() else { Issue.record("Expected a pushed screen"); return }
    #expect(screen.id.hasPrefix("clipboard-history"))
    #expect(ClipboardFeature.historyScreen(context: context).id != screen.id)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@MainActor
@Test func saveAsSnippetAppearsOnlyForTextWithAHookAndPassesTheFullText() async throws {
    let file = TemporaryDatabase()
    let context = FixtureContext(paths: AppPaths(dataDirectory: file.directory))
    let store = ClipboardStore.open(url: file.url)
    try store.setEnabled(true)
    let long = String(repeating: "스니펫 ", count: 300)
    try store.record(text: long)
    try store.record(.files(["file:///System/Applications/Calculator.app/"]))
    let model = ClipboardHistoryModel(history: ClipboardHistory(store: store, context: context))
    model.load()
    for _ in 0..<50 where !model.hasLoaded { try await Task.sleep(for: .milliseconds(20)) }
    let textEntry = try #require(model.entries.first { $0.kind == .text })
    let fileEntry = try #require(model.entries.first { $0.kind == .files })

    ClipboardFeature.onSaveAsSnippet = nil
    model.selectedID = textEntry.id
    #expect(!model.actions.contains { $0.id == "save-clipboard-as-snippet" })

    var saved: String?
    ClipboardFeature.onSaveAsSnippet = { saved = $0 }
    defer { ClipboardFeature.onSaveAsSnippet = nil }
    let action = try #require(model.actions.first { $0.id == "save-clipboard-as-snippet" })
    guard case .dismiss = await action.run() else { Issue.record("Expected dismiss"); return }
    #expect(saved == long)
    model.selectedID = fileEntry.id
    #expect(!model.actions.contains { $0.id == "save-clipboard-as-snippet" })
}
