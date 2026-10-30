import AppKit
import Observation
import PrismKit
import SwiftUI

/// A key panel that never activates Prism, so the previously active app keeps its place
/// for features that later paste or act on it.
final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PaletteView.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Prism is not the active app while the panel is key, so route ⌘C, ⌘V and ⌘, to the main menu here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Item shortcuts win over menu items, so ⇧⌘C copies a path instead of reaching Edit › Copy.
        (onKeyEquivalent?(event) ?? false)
            || super.performKeyEquivalent(with: event)
            || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    let model = PaletteModel()
    var onOpenSettings: (() -> Void)?
    var onWillShow: (() -> Void)?
    /// The app that was frontmost when the palette opened.
    private(set) var previousApplication: NSRunningApplication?

    private(set) lazy var panel: PalettePanel = makePanel()
    private var glass: PrismGlassView?

    static var backgroundOpacity: Double {
        let stored = UserDefaults.standard.object(forKey: PreferenceKey.backgroundOpacity) as? Double
        return min(max(stored ?? PrismTheme.defaultBackgroundOpacity, 0.2), 1)
    }

    override init() {
        super.init()
        model.onDismiss = { [weak self] in self?.hide() }
        observeWorkspace()
    }

    /// Hides a focused palette. A palette left open behind other windows (the expanded workspace) comes back
    /// to the front as it was instead of hiding.
    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            hide()
        } else if panel.isVisible {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            show()
        }
    }

    func show() {
        if !panel.isVisible {
            capturePreviousApplication()
            PrismLight.shared.playOpeningSweep()
            // Every presentation starts compact; an expanded screen grows from here.
            panel.setContentSize(PaletteView.size)
            isExpanded = false
            panel.level = .floating
        }
        onWillShow?()
        model.prepareForPresentation()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Set while `--render-snapshots` runs: screens are pushed onto the model without showing the panel.
    var isRenderingSnapshots = false

    /// Pushes onto the visible palette, so one screen can open another, or opens the palette on the screen.
    func show(screen: PaletteScreen) {
        if !panel.isVisible && !isRenderingSnapshots { show() }
        model.push(screen)
    }

    /// Runs a row's primary action from a command hotkey, without showing the palette unless the
    /// action pushes a screen.
    func runCommand(id: String) {
        if !panel.isVisible { capturePreviousApplication() }
        Task {
            guard let action = await model.item(withID: id)?.actions.first else { return }
            let pushes = model.pushCount
            switch await action.run() {
            case .dismiss:
                // An action that opened a palette screen itself (Notes) keeps it on screen.
                if model.pushCount == pushes { hide() }
            case .keepOpen: break
            case .push(let screen): show(screen: screen)
            case .notify(let message): model.onNotify?(message)
            case .refresh: model.refresh()
            }
        }
    }

    private func capturePreviousApplication() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The compact palette disappears when the user clicks elsewhere. The expanded workspace (AI chat) behaves
    /// like an ordinary window and stays, as in the Tauri app.
    func windowDidResignKey(_ notification: Notification) {
        guard !isExpanded else { return }
        hide()
    }

    // MARK: Workspace

    private var isExpanded = false

    private func observeWorkspace() {
        withObservationTracking {
            _ = model.isExpanded
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyWorkspace()
                self?.observeWorkspace()
            }
        }
    }

    /// Grows or shrinks the panel with its top edge fixed and centered horizontally, clamped to the display, using
    /// the Tauri timings: 0.42 s to expand and 0.32 s to collapse.
    private func applyWorkspace() {
        let expanded = model.isExpanded
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        panel.level = expanded ? .normal : .floating
        // A level change rebuilds the glass backdrop with the system blur radius.
        glass?.scheduleBlurRefresh()
        guard panel.isVisible, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            panel.setContentSize(expanded ? PaletteView.expandedSize : PaletteView.size)
            return
        }
        let size = expanded ? PaletteView.expandedSize : PaletteView.size
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        let from = panel.frame
        let target = NSRect(
            x: min(max(from.midX - width / 2, visible.minX), visible.maxX - width),
            y: min(max(from.maxY - height, visible.minY), visible.maxY - height),
            width: width, height: height
        ).integral
        if Motion.isReduced {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = expanded ? 0.42 : 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated { panel?.invalidateShadow() }
        })
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel()
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] event in self?.model.handleKeyEquivalent(event) ?? false }
        panel.onCancel = { [weak self] in
            guard let self, !model.handleEscape() else { return }
            hide()
        }

        let background = NSView.prismGlassBackground(opacity: Self.backgroundOpacity)
        background.setBlurRadius(Glass.blur)
        let hosting = FirstClickHostingView(rootView: PaletteView(model: model) { [weak self] in self?.onOpenSettings?() })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor),
        ])
        panel.contentView = background
        glass = background
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.glass?.setOpacity(Self.backgroundOpacity)
                self?.glass?.setBlurRadius(Glass.blur)
            }
        }
        return panel
    }

    /// Centers horizontally on the screen under the pointer, a little above the middle like Spotlight.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.2 - size.height
        )
        panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: max(visible.minY, origin.y).rounded()))
    }
}
