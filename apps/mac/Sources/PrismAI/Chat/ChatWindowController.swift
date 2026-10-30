import AppKit
import PrismKit
import SwiftUI

/// The AI chat window. It stays open beside other apps, remembers its frame, and is created on first use.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    let model: ChatModel
    private weak var context: (any PrismContext)?
    private var window: NSWindow?
    private static let autosaveName = "PrismAIChatWindow"
    static let defaultSize = NSSize(width: 1080, height: 760)
    static let minimumSize = NSSize(width: 760, height: 500)

    init(model: ChatModel, context: any PrismContext) {
        self.model = model
        self.context = context
        super.init()
        model.openSettings = { [weak context] in context?.openSettings(paneID: AIFeature.settingsPaneID) }
        model.captureRegion = { [weak self] in try await self?.captureRegion() }
    }

    var isVisible: Bool { window?.isVisible == true }

    /// The chat as an expanded palette screen: the palette grows into it and shrinks back to the search on Escape,
    /// as in the Tauri app. A non-empty draft or image starts a new unsent conversation; otherwise the latest resumes.
    func screen(draft: String = "", image: ChatImage? = nil) -> PaletteScreen {
        model.load()
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil {
            Task { await model.accept(text: draft, image: image) }
        }
        model.refreshConfiguration()
        let chat = model
        return PaletteScreen(id: "ai-chat", title: L("AI Chat"), expanded: true) { [weak self] in
            ChatRootView(model: chat, onClose: { [weak self] in
                chat.saveOnClose()
                self?.context?.popScreen()
            }, onExport: { [weak self] session in self?.export(session) }, chooseFolder: { Self.chooseFolder() })
        }
    }

    /// Opens the chat. A non-empty draft or image starts a new unsent conversation; otherwise the latest resumes.
    /// `origin` is the palette's frame when the chat opens from it; the window then grows out of the palette.
    func show(draft: String = "", image: ChatImage? = nil, growingFrom origin: NSRect? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        model.load()
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil {
            Task { await model.accept(text: draft, image: image) }
        }
        NSApp.bringForward()
        if let origin, !window.isVisible, !Self.reduceMotion {
            grow(window, from: origin)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        collapseTarget = origin
        model.refreshConfiguration()
    }

    func close() {
        model.saveOnClose()
        guard let window, window.isVisible else { return }
        if let target = collapseTarget, !Self.reduceMotion {
            shrink(window, into: target)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: Expand and collapse

    /// The palette frame the chat grew from, so closing it shrinks back to the same place.
    private var collapseTarget: NSRect?
    private var isAnimatingFrame = false

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Starts at the palette's frame and eases out to the chat's own frame on the palette's display (0.42 s, as in Tauri).
    private func grow(_ window: NSWindow, from origin: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(origin) } ?? NSScreen.main
        var target = window.frame
        if let visible = screen?.visibleFrame, !visible.contains(target) {
            target = Self.initialFrame(on: visible)
        }
        isAnimatingFrame = true
        window.alphaValue = 0
        window.setFrame(origin, display: false)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isAnimatingFrame = false
                window.saveFrame(usingName: Self.autosaveName)
            }
        })
    }

    /// Shrinks toward the palette's place and fades out (0.32 s), keeping the saved full-size frame.
    private func shrink(_ window: NSWindow, into target: NSRect) {
        let full = window.frame
        isAnimatingFrame = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.setFrame(full, display: false)
                window.alphaValue = 1
                self?.isAnimatingFrame = false
                window.saveFrame(usingName: Self.autosaveName)
            }
        })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("AI Chat")
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = Self.minimumSize
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        let root = ChatRootView(model: model, onClose: { [weak self] in self?.close() },
                                onExport: { [weak self] session in self?.export(session) },
                                chooseFolder: { Self.chooseFolder() })
        window.contentViewController = NSHostingController(rootView: root)
        if !window.setFrameUsingName(Self.autosaveName) {
            window.setFrame(Self.initialFrame(on: NSScreen.main?.visibleFrame), display: false)
        }
        // Frames are saved explicitly after each expand/collapse so animation steps are never persisted.
        return window
    }

    /// 1080×760 centered, clamped to the display work area.
    static func initialFrame(on visible: NSRect?) -> NSRect {
        guard let visible else { return NSRect(origin: .zero, size: defaultSize) }
        let width = min(defaultSize.width, visible.width), height = min(defaultSize.height, visible.height)
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height).integral
    }

    /// Settings may have changed in another window; recheck keys, tools and the default model on focus.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshConfiguration()
    }

    func windowWillClose(_ notification: Notification) {
        model.saveOnClose()
        if !isAnimatingFrame, let window { window.saveFrame(usingName: Self.autosaveName) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        window?.saveFrame(usingName: Self.autosaveName)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAnimatingFrame, let window, window.isVisible, window.alphaValue == 1 else { return }
        window.saveFrame(usingName: Self.autosaveName)
    }

    // MARK: Export

    private func export(_ session: ChatSession?) {
        let (name, text) = model.exportMarkdown(session)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writePrivately(text, to: url)
                self?.model.notice = L("Conversation exported.")
            } catch {
                self?.model.notice = L("Could not export the conversation.")
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    static func writePrivately(_ text: String, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = L("Choose a folder AI can read")
        panel.prompt = L("Allow")
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Screen capture

    private var capturingRegion = false

    /// The system selector owns the crosshair and Escape. Prism's windows hide while it runs.
    func captureRegion() async throws -> ChatImage? {
        guard !capturingRegion else { throw AIError(L("A screen region is already being selected.")) }
        capturingRegion = true
        // The chat lives in the palette; step it aside for the system selector and bring it back unchanged.
        context?.suspendPalette()
        defer {
            capturingRegion = false
            context?.resumePalette()
        }
        try? await Task.sleep(for: .milliseconds(180))
        return try await Task.detached { try ScreenRegionCapture.capture() }.value
    }
}

/// Interactive region selection through `/usr/sbin/screencapture`, as the Tauri host does.
enum ScreenRegionCapture {
    static func capture() throws -> ChatImage? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prism-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "region.png")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", "-x", "-t", "png", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AIError(L("Could not start screen region selection.")) }
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw AIError(L("Screen selection timed out. Try again."))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Escape produces no file. Missing permission also produces none, so tell those apart.
        guard FileManager.default.fileExists(atPath: file.path) else {
            if process.terminationStatus == 0 || CGPreflightScreenCaptureAccess() { return nil }
            throw AIError(L("Could not capture the screen. Check Prism's Screen Recording permission in System Settings."))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > ChatImageCodec.maxFileBytes { throw AIError(L("The selected area is too large. Choose a smaller area.")) }
        return try ChatImageCodec.encode(fileAt: file, allowedTypes: nil)
    }
}
