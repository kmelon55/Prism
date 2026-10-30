import AppKit
import PrismKit
import SwiftUI
import Testing
@testable import PrismClipboard

/// Renders history screen states that the app's `--render-snapshots` cannot reach (other selections, the
/// ⌘K panel, the delete-all confirmation, disabled and empty history). Runs only when
/// `PRISM_CLIPBOARD_SNAPSHOTS` names an output directory.
@MainActor
final class FixtureContext: PrismContext {
    let paths: AppPaths
    var previousApplication: NSRunningApplication? { nil }
    init(paths: AppPaths) { self.paths = paths }
    func showPalette() {}
    func hidePalette() {}
    func showPalette(screen: PaletteScreen) {}
    func openSettings(paneID: String?) {}
    func showHUD(_ message: String) {}
}

private let snapshotDirectory = ProcessInfo.processInfo.environment["PRISM_CLIPBOARD_SNAPSHOTS"]

@MainActor
@Test(.enabled(if: snapshotDirectory != nil))
func renderHistoryScreenStates() async throws {
    let output = URL(filePath: snapshotDirectory!, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let file = TemporaryDatabase()
    let store = ClipboardStore.open(url: file.url)
    try store.setEnabled(true)
    let now = ClipboardClock.nowMs()
    try store.record(text: "#7C5CFF", at: now - 90_000_000)
    try store.record(.files(["file:///System/Applications/Calculator.app/", "file:///System/Applications/TextEdit.app/"]), at: now - 7_200_000)
    try store.record(ClipboardImages.payload(bytes: encode(image(width: 480, height: 300), as: .png), mimeType: "image/png"), at: now - 1_800_000)
    try store.record(text: "https://developer.apple.com/documentation/appkit/nspasteboard", at: now - 600_000)
    try store.record(text: "Meeting notes — Q4 roadmap\n- Ship the native clipboard history\n- 한글 입력 테스트", at: now - 30_000)
    let history = ClipboardHistory(store: store, context: FixtureContext(paths: AppPaths(dataDirectory: file.directory)))

    for appearance in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let model = ClipboardHistoryModel(history: history)
        model.load()
        for _ in 0..<50 where !model.hasLoaded { try await Task.sleep(for: .milliseconds(20)) }
        for (index, name) in [(2, "image"), (3, "files"), (4, "color")] {
            model.selectedID = model.entries[index].id
            await render(model, to: output.appending(path: "history-\(name)-\(appearance).png"))
        }
        model.selectedID = model.entries[0].id
        model.toggleActionPanel()
        await render(model, to: output.appending(path: "history-actions-\(appearance).png"))
        model.toggleActionPanel()
        model.isConfirmingClear = true
        await render(model, to: output.appending(path: "history-confirm-\(appearance).png"))
        model.isConfirmingClear = false
        model.query = "no such entry"
        try await Task.sleep(for: .milliseconds(200))
        await render(model, to: output.appending(path: "history-empty-\(appearance).png"))
    }
    try store.setEnabled(false)
    let disabled = ClipboardHistoryModel(history: history)
    disabled.load()
    for _ in 0..<50 where !disabled.hasLoaded { try await Task.sleep(for: .milliseconds(20)) }
    await render(disabled, to: output.appending(path: "history-disabled-dark.png"))
}

@MainActor
private func render(_ model: ClipboardHistoryModel, to url: URL) async {
    let size = CGSize(width: 760, height: 480)
    let hosting = NSHostingView(rootView: ClipboardHistoryView(model: model).frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(450))
    hosting.layoutSubtreeIfNeeded()
    guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    try? representation.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
}
