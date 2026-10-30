import AppKit
import SwiftUI
import Testing
@testable import PrismEmoji

/// Renders the picker to PNG when `PRISM_SNAPSHOT_DIR` is set, for visual checks without showing windows.
/// `PRISM_SNAPSHOT_APPEARANCE=dark` and `PRISM_SNAPSHOT_LANG=ko` select the variant.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["PRISM_SNAPSHOT_DIR"] != nil))
func renderEmojiPickerSnapshots() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(filePath: environment["PRISM_SNAPSHOT_DIR"]!)
    let dark = environment["PRISM_SNAPSHOT_APPEARANCE"] == "dark"
    let korean = environment["PRISM_SNAPSHOT_LANG"] == "ko"
    let suffix = (dark ? "dark" : "light") + (korean ? "-ko" : "")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared

    let data = FileManager.default.temporaryDirectory.appending(path: "prism-emoji-snap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try JSONEncoder().encode(["👍", "❤️", "😂", "🎉", "👩🏽‍💻", "🇰🇷"]).write(to: data.appending(path: "emoji-recent-v1.json"))
    let catalog = try EmojiCatalog.load(from: EmojiCatalog.bundledDataURL!)

    func model(canPaste: Bool = true) -> EmojiPickerModel {
        EmojiPickerModel(
            actions: EmojiActions(copy: { _ in }, paste: { _ in }, canPaste: { canPaste }),
            recents: EmojiRecents(url: data.appending(path: "emoji-recent-v1.json")),
            defaults: UserDefaults(suiteName: "prism-emoji-snap")!, useKorean: korean, loader: { catalog }
        )
    }

    var scenes: [(String, EmojiPickerModel)] = []
    let recent = model(); scenes.append(("recent", recent))
    let smileys = model(); scenes.append(("smileys", smileys))
    let search = model(); scenes.append(("search", search))
    let failed = model(canPaste: false); scenes.append(("failed", failed))
    let empty = model(); scenes.append(("empty", empty))
    for (_, model) in scenes { await model.load() }
    smileys.select(category: "Smileys & Emotion"); smileys.selection = 14
    search.query = korean ? "하트" : "heart"; search.tone = .none
    failed.query = "따봉"; await failed.performPrimary()
    empty.query = "zzzz-nothing"

    for (name, model) in scenes {
        let view = EmojiPickerView(model: model, onClose: {}, onOpenAccessibilitySettings: {})
            .frame(width: 760, height: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: korean ? "ko" : "en"))
        try await snapshot(view, dark: dark, to: directory.appending(path: "emoji-\(name)-\(suffix).png"))
    }
}

@MainActor
func snapshot<Content: View>(_ view: Content, dark: Bool, to url: URL) async throws {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 760, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = hosting.appearance
    window.contentView = hosting
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(500))
    hosting.layoutSubtreeIfNeeded()
    let representation = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    try representation.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
}
