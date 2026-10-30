import AppKit
import PrismKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The actions every file row offers, shared by root results and the Files screen.
@MainActor
enum FileActions {
    static func actions(for hit: FileHit, openWith: @escaping @MainActor (FileHit) -> PaletteActionOutcome) -> [PaletteAction] {
        let url = hit.url
        return [
            PaletteAction(id: "file-open", title: String(localized: "Open", bundle: .module), systemImage: hit.isDirectory ? "folder" : "arrow.up.forward.app") {
                guard exists(hit) else { return missing }
                NSWorkspace.shared.open(url)
                return .dismiss
            },
            PaletteAction(id: "file-reveal", title: String(localized: "Show in Finder", bundle: .module), systemImage: "folder",
                          shortcut: .init("r", modifiers: [.command, .shift])) {
                guard exists(hit) else { return missing }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .dismiss
            },
            PaletteAction(id: "file-open-with", title: String(localized: "Open With…", bundle: .module), systemImage: "arrow.up.right.square",
                          shortcut: .init("o", modifiers: .command)) {
                guard exists(hit) else { return missing }
                return openWith(hit)
            },
            PaletteAction(id: "file-quick-look", title: String(localized: "Quick Look", bundle: .module), systemImage: "eye",
                          shortcut: .init("y", modifiers: .command)) {
                guard exists(hit) else { return missing }
                QuickLookPanel.shared.toggle(url)
                return .keepOpen
            },
            PaletteAction(id: "file-copy", title: String(localized: "Copy Path", bundle: .module), systemImage: "doc.on.clipboard",
                          shortcut: .init("c", modifiers: [.command, .shift])) {
                PasteService.copy(hit.path)
                return .notify(String(localized: "Path copied", bundle: .module))
            },
            PaletteAction(id: "file-copy-file", title: String(localized: "Copy File", bundle: .module), systemImage: "doc.on.doc",
                          shortcut: .init("c", modifiers: [.command, .option])) {
                guard exists(hit) else { return missing }
                PasteService.copy([url as NSURL])
                return .notify(String(localized: "File copied", bundle: .module))
            },
        ]
    }

    static func exists(_ hit: FileHit) -> Bool {
        FileManager.default.fileExists(atPath: hit.path)
    }

    static var missing: PaletteActionOutcome {
        .notify(String(localized: "The file was moved or deleted", bundle: .module))
    }

    /// The localized kind, such as "PDF document" or "Folder", shown as the row accessory.
    static func kind(of hit: FileHit) -> String {
        if hit.isDirectory { return String(localized: "Folder", bundle: .module) }
        let ext = (hit.name as NSString).pathExtension
        // Some type names are long ("Office Open XML word processing document"); the extension reads better.
        if let description = UTType(filenameExtension: ext)?.localizedDescription, description.count <= 24 { return description }
        return ext.isEmpty ? String(localized: "File", bundle: .module) : ext.uppercased()
    }
}

/// A floating Quick Look panel that never takes keyboard focus from the palette, so ⌘Y toggles it while the
/// selection keeps moving. `QLPreviewPanel` needs a controller in the key window's responder chain, which a
/// feature cannot provide inside the shell's palette, so this hosts a `QLPreviewView` directly.
@MainActor
final class QuickLookPanel: NSObject, NSWindowDelegate {
    static let shared = QuickLookPanel()

    private var panel: NSPanel?
    private var previewView: QLPreviewView?
    private var currentURL: URL?
    private var observer: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(_ url: URL) {
        if isVisible, currentURL == url { close() } else { show(url) }
    }

    /// Follows the selection while the panel is open.
    func updateIfVisible(_ url: URL?) {
        guard isVisible, let url, url != currentURL else { return }
        show(url)
    }

    func show(_ url: URL) {
        let anchor = NSApp.keyWindow
        let panel = panel ?? makePanel()
        currentURL = url
        previewView?.previewItem = url as NSURL
        panel.title = FileManager.default.displayName(atPath: url.path)
        if !panel.isVisible {
            position(panel, beside: anchor)
            panel.orderFront(nil)
        }
        // Close with the palette: when the window that opened the preview loses focus, the preview goes too.
        if let anchor, observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: anchor, queue: .main) { _ in
                MainActor.assumeIsolated { QuickLookPanel.shared.close() }
            }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        currentURL = nil
        // Release the preview and its document so a closed panel holds no memory.
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let view = QLPreviewView(frame: panel.contentLayoutRect, style: .normal)!
        view.autoresizingMask = [.width, .height]
        view.shouldCloseWithWindow = true
        panel.contentView = view
        previewView = view
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, beside anchor: NSWindow?) {
        guard let anchor, let screen = anchor.screen ?? NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.y = min(max(anchor.frame.maxY - frame.height, visible.minY), visible.maxY - frame.height)
        if anchor.frame.maxX + 12 + frame.width <= visible.maxX {
            frame.origin.x = anchor.frame.maxX + 12
        } else if anchor.frame.minX - 12 - frame.width >= visible.minX {
            frame.origin.x = anchor.frame.minX - 12 - frame.width
        } else {
            frame.origin.x = visible.maxX - frame.width
        }
        panel.setFrame(frame, display: false)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }
}
