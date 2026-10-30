import AppKit
import SwiftUI
import Testing
@testable import PrismFiles

/// Renders the Files screen and settings pane to PNG when `PRISM_SNAPSHOT_DIR` is set. Uses fixture folders
/// only; Spotlight is replaced so no real files appear. `PRISM_SNAPSHOT_APPEARANCE=dark` selects dark mode.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["PRISM_SNAPSHOT_DIR"] != nil))
func renderFilesSnapshots() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(filePath: environment["PRISM_SNAPSHOT_DIR"]!)
    let dark = environment["PRISM_SNAPSHOT_APPEARANCE"] == "dark"
    let korean = environment["PRISM_SNAPSHOT_LANG"] == "ko"
    let suffix = (dark ? "dark" : "light") + (korean ? "-ko" : "")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared

    let fixture = Fixture()
    for name in ["Projects/Trip plan 2026.pages", "Projects/plan.md", "Projects/Budget plan.numbers", "Projects/floor-plan.png",
                 "Projects/Archive/old plan.txt", "Projects/계획서 초안.docx", "Projects/plans/README.md"] {
        fixture.write(name)
    }
    try "# Plan\n\n- Book flights\n- Pack\n".write(toFile: fixture.root + "/Projects/plan.md", atomically: true, encoding: .utf8)
    let data = Fixture()
    let defaults = UserDefaults(suiteName: "prism-files-snap")!
    defaults.set(true, forKey: FileSearchService.spotlightDefaultsKey)
    let service = FileSearchService(store: SearchRootsStore(url: URL(filePath: data.root + "/library-v1.sqlite3")), defaults: defaults,
                                    spotlight: { _ in [] }, recent: { [] })
    try service.addRoot(URL(filePath: fixture.root + "/Projects"))
    await service.waitForIndex()

    let model = FileBrowserModel(service: service, context: nil, query: korean ? "계획" : "plan")
    model.scheduleSearch(immediately: true)
    while !model.isCurrent { await Task.yield() }
    model.selection = 1
    try await render(FileBrowserView(model: model, onClose: {}), size: CGSize(width: 760, height: 480), dark: dark, korean: korean,
                     to: directory.appending(path: "files-browser-\(suffix).png"))
    model.toggleActions()
    try await render(FileBrowserView(model: model, onClose: {}), size: CGSize(width: 760, height: 480), dark: dark, korean: korean,
                     to: directory.appending(path: "files-actions-\(suffix).png"))
    let empty = FileBrowserModel(service: service, context: nil, query: "zzz-nothing")
    empty.scheduleSearch(immediately: true)
    while !empty.isCurrent { await Task.yield() }
    try await render(FileBrowserView(model: empty, onClose: {}), size: CGSize(width: 760, height: 480), dark: dark, korean: korean,
                     to: directory.appending(path: "files-empty-\(suffix).png"))
    try await render(OpenWithView(hit: FileHit(path: fixture.root + "/Projects/plan.md", isDirectory: false), onOpen: {}, onCancel: {}),
                     size: CGSize(width: 760, height: 480), dark: dark, korean: korean, to: directory.appending(path: "files-openwith-\(suffix).png"))
    try await render(FilesSettingsView(service: service), size: CGSize(width: 560, height: 560), dark: dark, korean: korean,
                     to: directory.appending(path: "files-settings-\(suffix).png"))
}

@MainActor
private func render<Content: View>(_ view: Content, size: CGSize, dark: Bool, korean: Bool, to url: URL) async throws {
    let root = view.frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: korean ? "ko" : "en"))
    let hosting = NSHostingView(rootView: root)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = hosting.appearance
    window.contentView = hosting
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(900))
    hosting.layoutSubtreeIfNeeded()
    let representation = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    try representation.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
}
