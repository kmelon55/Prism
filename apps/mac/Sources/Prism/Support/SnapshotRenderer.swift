import AppKit
import PrismKit
import SwiftUI

/// Renders the palette and every settings pane to PNG files without showing windows on screen, so changes
/// can be checked visually from the command line:
///
///     Prism --render-snapshots <dir> [--appearance light|dark] [--query <text>]... [--actions <text>]...
///           [--open <text>]... [--open-id <command id>]... [--pane <id>]... [--settings-height <points>]
///
/// `--query` renders the root results for that text. `--actions` renders them with the ⌘K action panel open
/// for the first result. `--open` also runs the first result's primary action and renders the screen it
/// pushes. `--open-id` does the same for a command ID such as `prism:notes`, so a same-named app is never
/// launched. Without `--pane`, every settings pane is rendered.
@MainActor
enum SnapshotRenderer {
    static func render(to directory: URL, palette: PaletteController, settings: SettingsWindowController) async {
        let arguments = ProcessInfo.processInfo.arguments
        func values(_ flag: String) -> [String] {
            arguments.indices.filter { arguments[$0] == flag && arguments.indices.contains($0 + 1) }.map { arguments[$0 + 1] }
        }
        if let appearance = values("--appearance").first {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        palette.isRenderingSnapshots = true

        let model = palette.model
        let queries = [""] + values("--query")
        for query in queries {
            await settle(model, query: query)
            await snapshot(PaletteView(model: model) {}, size: PaletteView.size, to: directory.appending(path: "palette-\(slug(query)).png"))
        }
        for query in values("--actions") {
            await settle(model, query: query)
            model.toggleActionPanel()
            await snapshot(PaletteView(model: model) {}, size: PaletteView.size, to: directory.appending(path: "actions-\(slug(query)).png"))
            model.closeActionPanel()
        }
        for query in values("--open") {
            await settle(model, query: query)
            model.activate()
            try? await Task.sleep(for: .milliseconds(400))
            let size = model.isExpanded ? PaletteView.expandedSize : PaletteView.size
            await snapshot(PaletteView(model: model) {}, size: size, to: directory.appending(path: "screen-\(slug(query)).png"))
        }

        for id in values("--open-id") {
            await settle(model, query: "")
            guard let action = await model.item(withID: id)?.actions.first else { continue }
            model.perform(action)
            try? await Task.sleep(for: .milliseconds(400))
            let size = model.isExpanded ? PaletteView.expandedSize : PaletteView.size
            await snapshot(PaletteView(model: model) {}, size: size, to: directory.appending(path: "screen-\(slug(id)).png"))
        }

        let paneFilter = Set(values("--pane"))
        // `--settings-height` renders taller than the window so a whole page fits in one image.
        let height = values("--settings-height").first.flatMap(Double.init) ?? SettingsWindowController.size.height
        for pane in settings.model.panes where paneFilter.isEmpty || paneFilter.contains(pane.id) {
            settings.model.selection = pane.id
            await snapshot(SettingsRootView(model: settings.model), size: CGSize(width: SettingsWindowController.size.width, height: height),
                           to: directory.appending(path: "settings-\(pane.id).png"))
        }
        print("Snapshots written to \(directory.path)")
    }

    private static func settle(_ model: PaletteModel, query: String) async {
        model.prepareForPresentation()
        model.query = query
        model.refresh()
        for _ in 0..<50 where model.hasPendingProviders {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func snapshot<Content: View>(_ view: Content, size: CGSize, to url: URL) async {
        // Glass does not render offscreen; an opaque shell tint stands in for it.
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: PrismTheme.shellTint(opacity: 1))))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        // Never visible: macOS may pull an offscreen window onto a display, so it is also fully transparent,
        // click-through and below everything. `cacheDisplay` draws the views regardless of window alpha.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(350))
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private static func slug(_ query: String) -> String {
        guard !query.isEmpty else { return "root" }
        let allowed = query.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed.prefix(40))
    }
}
