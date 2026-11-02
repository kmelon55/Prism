import AppKit
import PrismKit
import PrismNotch
import PrismSystem
import SwiftUI

/// Renders the palette and every settings pane to PNG files without showing windows on screen, so changes
/// can be checked visually from the command line:
///
///     Prism --render-snapshots <dir> [--appearance light|dark] [--query <text>]... [--actions <text>]...
///           [--open <text>]... [--open-id <command id>]... [--pane <id>]... [--settings-height <points>]
///           [--snapshot-scale 1|2] (requires a connected display with that backing scale)
///
/// `--query` renders the root results for that text. `--actions` renders them with the ⌘K action panel open
/// for the first result. `--open` also runs the first result's primary action and renders the screen it
/// pushes. `--open-id` does the same for a command ID such as `prism:notes`, so a same-named app is never
/// launched. Without `--pane`, every settings pane is rendered.
@MainActor
enum SnapshotRenderer {
    private static var snapshotOrigin = CGPoint(x: -20_000, y: -20_000)

    static func render(to directory: URL, palette: PaletteController, settings: SettingsWindowController) async {
        let arguments = ProcessInfo.processInfo.arguments
        func values(_ flag: String) -> [String] {
            arguments.indices.filter { arguments[$0] == flag && arguments.indices.contains($0 + 1) }.map { arguments[$0 + 1] }
        }
        if let requested = values("--snapshot-scale").first {
            guard let scale = Double(requested),
                  let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == scale }) else {
                print("No connected display matches snapshot scale \(requested)")
                return
            }
            // Still fully transparent, click-through and below the desktop. Choosing a display gives
            // native image views the real backing density rather than rescaling a Retina screenshot.
            snapshotOrigin = CGPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20)
        }
        if let appearance = values("--appearance").first {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        palette.isRenderingSnapshots = true

        let model = palette.model
        // Render one task-sized page for focused visual review, with no hardware effects.
        if let widget = values("--notch-only").first {
            let utility = widget.hasPrefix("audio-") || widget.hasPrefix("keep-awake")
            let selected = widget.hasPrefix("audio-") ? "audio-output" : widget.hasPrefix("keep-awake") ? "keep-awake" : widget
            await snapshot(NotchFeature.snapshot(mode: "expanded", widget: selected,
                                                 widgets: utility ? SystemFeature.utilitySnapshotWidgets(state: widget) : nil),
                           size: NotchFeature.snapshotSize(mode: "expanded"),
                           to: directory.appending(path: "notch-\(slug(widget)).png"))
            print("Snapshot written to \(directory.path)")
            return
        }
        if arguments.contains("--notch-interactions") {
            do { try await NotchFeature.verifyInteractions(to: directory.appending(path: "notch-interactions.json")) }
            catch { print("Notch interaction verification failed: \(error)") }
        }
        if arguments.contains("--palette-interactions") {
            await selectionSnapshots(model, to: directory)
        }
        if arguments.contains("--notch-motion") {
            do { try await NotchFeature.renderMotionSnapshots(to: directory.appending(path: "motion")) }
            catch { print("Notch motion snapshots failed: \(error)") }
        }
        if arguments.contains("--notch") {
            for camera in [true, false] {
                for mode in ["compact", "preview", "expanded"] {
                    await snapshot(NotchFeature.snapshot(mode: mode, camera: camera),
                                   size: NotchFeature.snapshotSize(mode: mode, camera: camera),
                                   to: directory.appending(path: "notch-\(mode)\(camera ? "" : "-external").png"))
                }
            }
            await snapshot(NotchFeature.snapshot(mode: "compact", active: true),
                           size: NotchFeature.snapshotSize(mode: "compact", active: true),
                           to: directory.appending(path: "notch-compact-active.png"))
            for widget in values("--notch-widget") {
                await snapshot(NotchFeature.snapshot(mode: "expanded", widget: widget), size: NotchFeature.snapshotSize(mode: "expanded"),
                               to: directory.appending(path: "notch-\(slug(widget)).png"))
            }
            for widget in values("--notch-utility") {
                await snapshot(NotchFeature.snapshot(mode: "expanded", widget: widget, widgets: SystemFeature.utilitySnapshotWidgets()),
                               size: NotchFeature.snapshotSize(mode: "expanded"),
                               to: directory.appending(path: "notch-\(slug(widget)).png"))
            }
        }
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

    private static func selectionSnapshots(_ model: PaletteModel, to directory: URL) async {
        await settle(model, query: "noch")
        let host = NSHostingView(rootView: PaletteView(model: model) {}.background(Color.black))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: PaletteView.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var states: [[String: Any]] = []
        for step in 0..<5 {
            if step == 1 || step == 2 { model.moveSelection(by: 1) }
            if step == 3, let first = model.results.first { model.selectFromPointer(id: first.id) }
            if step == 4, model.results.count > 1 { model.selectFromPointer(id: model.results[1].id) }
            try? await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            states.append(["step": step, "selection": model.selection,
                           "selectedRows": model.sections.flatMap(\.rows).filter { $0.index == model.selection }.map(\.id)])
            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "selection-\(step).png"))
            }
        }
        try? JSONSerialization.data(withJSONObject: states, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "selection-states.json"))
    }

    private static func snapshot<Content: View>(_ view: Content, size: CGSize, to url: URL) async {
        // Glass does not render offscreen; an opaque shell tint stands in for it.
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: PrismTheme.shellTint(opacity: 1))))
        let window = NSWindow(contentRect: NSRect(origin: snapshotOrigin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        // Never visible: macOS may pull an offscreen window onto a display, so it is also fully transparent,
        // click-through and below everything. `cacheDisplay` draws the views regardless of window alpha.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--notch-only") ? 1200 : 350))
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
