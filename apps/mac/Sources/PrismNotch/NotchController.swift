import AppKit
import Observation
import PrismKit
import SwiftUI

final class NotchPanel: NSPanel {
    var allowsKeyboard = false
    var dismiss: (() -> Void)?
    var willInteract: (() -> Void)?
    var didInteract: (() -> Void)?
    private(set) var isHandlingPointer = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            isHandlingPointer = true
            willInteract?()
        case .mouseMoved:
            // Native controls can consume mouse-up in their tracking loop. A normal move
            // (as opposed to a drag) also ends that capture.
            if isHandlingPointer { isHandlingPointer = false; didInteract?() }
        default: break
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            isHandlingPointer = false
            didInteract?()
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    }
}

@MainActor
final class NotchSurface {
    var display: NotchDisplay
    let session = NotchDisplaySession()
    let panel: NotchPanel
    let canvas: NotchCanvas
    var pointerInside = false
    var hoverTask: Task<Void, Never>?

    init(display: NotchDisplay, offscreen: Bool) {
        self.display = display
        let frame = display.geometry(active: false).stageFrame
        panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = offscreen ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1) : .statusBar
        panel.collectionBehavior = display.collectionBehavior
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        if offscreen { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        canvas = NotchCanvas(frame: CGRect(origin: .zero, size: frame.size))
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas
    }

    func dispose() {
        hoverTask?.cancel(); hoverTask = nil
        canvas.onFrame = nil
        canvas.clear()
        panel.dismiss = nil
        panel.willInteract = nil
        panel.didInteract = nil
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor
final class NotchController {
    let model: NotchModel
    private weak var context: (any PrismContext)?
    private(set) var surfaces: [String: NotchSurface] = [:]
    private let displays: () -> [NotchDisplay]
    /// Diagnostics use real native panels, fully transparent and without global event monitors.
    private let rendersOffscreen: Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var monitors: [Any] = []
    private var hiddenForSession = false
    private var screenLocked = false
    private var trackingMenus = 0
    private var started = false

    init(model: NotchModel, context: (any PrismContext)? = nil,
         displays: @escaping () -> [NotchDisplay] = { NotchDisplay.connected() }, rendersOffscreen: Bool = false) {
        self.model = model
        self.context = context
        self.displays = displays
        self.rendersOffscreen = rendersOffscreen
        model.onChange = { [weak self] in self?.reconcile() }
        model.onTimerFinished = { [weak self] in
            guard let self, !self.surfaces.isEmpty, !self.hiddenForSession, !self.rendersOffscreen else { return }
            // One shared deadline and one sound, regardless of how many screens show the timer.
            NSSound.beep()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        model.start()
        observeActivity()
        if !rendersOffscreen {
            observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.reconcile() }
            observe(.default, NSMenu.didBeginTrackingNotification) { $0.trackingMenus += 1 }
            observe(.default, NSMenu.didEndTrackingNotification) { $0.trackingMenus = max(0, $0.trackingMenus - 1) }
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
                observe(workspace, name) { $0.suspend() }
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
                observe(workspace, name) { $0.resume() }
            }
            observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) {
                $0.screenLocked = true; $0.suspend()
            }
            observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
                $0.screenLocked = false; $0.resume()
            }
        }
        reconcile()
    }

    func stop() {
        started = false
        removeSurfaces()
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        model.onChange = nil
        model.onTimerFinished = nil
        model.stop()
    }

    private func observeActivity() {
        guard started else { return }
        withObservationTracking { _ = model.hasActivity } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeActivity()
                self?.reconcile()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (NotchController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func suspend() {
        hiddenForSession = true
        removeSurfaces()
    }

    func resume() {
        guard !screenLocked else { return }
        hiddenForSession = false
        model.refreshTimer()
        reconcile()
    }

    /// Launcher commands open just the selected display under the pointer, with a deterministic fallback.
    @discardableResult func open(on id: String? = nil, widget: String? = nil) -> Bool {
        guard started, !hiddenForSession else { return false }
        if let widget, model.availableIDs.contains(widget), !model.visibleIDs.contains(widget) {
            guard model.change({ $0.widgets.append(widget) }) else { return false }
        }
        if !model.preferences.enabled, !model.change({ $0.enabled = true }) { return false }
        let eligible = model.preferences.displays.resolve(in: displays())
        let chosen = id ?? eligible.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.id
            ?? eligible.first(where: \.isMain)?.id ?? eligible.first?.id
        guard let chosen, let surface = surfaces[chosen] else { return false }
        surface.hoverTask?.cancel()
        if let widget, model.visibleIDs.contains(widget) {
            surface.session.selection = widget
        } else if model.preferences.countdown.phase != .idle, model.visibleIDs.contains("timer") {
            surface.session.selection = "timer"
        } else if surface.session.presentation.mode != .expanded, let activity = model.activeWidget {
            surface.session.selection = activity.id
        }
        surface.session.presentation.open()
        render(surface)
        return true
    }

    func close(on id: String) {
        guard let surface = surfaces[id] else { return }
        surface.hoverTask?.cancel()
        surface.session.presentation.close()
        if surface.panel.isKeyWindow { surface.panel.resignKey() }
        render(surface)
    }

    private func toggle(on id: String) {
        if surfaces[id]?.session.presentation.mode == .expanded { close(on: id) } else { open(on: id) }
    }

    func hover(_ inside: Bool, on id: String) {
        guard let surface = surfaces[id] else { return }
        surface.hoverTask?.cancel()
        guard !surface.panel.isHandlingPointer else { return }
        if inside {
            guard model.preferences.hoverPreview, surface.session.presentation.mode == .compact,
                  !surface.session.presentation.suppressHover else { return }
        }
        surface.hoverTask = Task { [weak self, weak surface] in
            try? await Task.sleep(for: .milliseconds(inside ? 220 : 180))
            guard !Task.isCancelled, let self, let surface, self.surfaces[id] === surface else { return }
            guard !surface.panel.isHandlingPointer else { return }
            let before = surface.session.presentation
            if inside { surface.session.presentation.preview() } else { surface.session.presentation.leave() }
            if surface.session.presentation != before { self.render(surface) }
        }
    }

    func reconcile() {
        guard started else { return }
        let connected = displays()
        // Persist legacy IDs/names without recursively reconciling from the save callback.
        let onChange = model.onChange
        model.onChange = nil
        model.upgradeDisplayIDs(using: connected)
        model.onChange = onChange
        guard model.preferences.enabled, !hiddenForSession else { removeSurfaces(); return }
        let chosen = model.preferences.displays.resolve(in: connected)
        let ids = Set(chosen.map(\.id))
        for id in Array(surfaces.keys) where !ids.contains(id) { surfaces.removeValue(forKey: id)?.dispose() }
        for display in chosen {
            let surface: NotchSurface
            if let current = surfaces[display.id] {
                surface = current
                surface.display = display
                if surface.panel.collectionBehavior != display.collectionBehavior {
                    surface.panel.collectionBehavior = display.collectionBehavior
                }
            } else {
                surface = NotchSurface(display: display, offscreen: rendersOffscreen)
                surfaces[display.id] = surface
                surface.panel.dismiss = { [weak self] in self?.close(on: display.id) }
                surface.panel.willInteract = { [weak surface] in
                    surface?.hoverTask?.cancel()
                    surface?.hoverTask = nil
                }
                surface.panel.didInteract = { [weak self] in self?.updatePointer(on: display.id) }
                surface.canvas.onFrame = { [weak self] in self?.updatePointer(on: display.id) }
            }
            render(surface)
        }
        if surfaces.isEmpty { removeMonitors() } else { installMonitors() }
    }

    private func render(_ surface: NotchSurface) {
        let id = surface.display.id
        let geometry = surface.display.geometry(active: model.hasActivity)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "reduceMotion")
        let relocating = surface.panel.frame != geometry.stageFrame
        if relocating { surface.canvas.clear(); surface.panel.setFrame(geometry.stageFrame, display: false) }
        let mode = surface.session.presentation.mode
        surface.panel.allowsKeyboard = mode == .expanded
        let view = NotchView(model: model, session: surface.session, geometry: geometry, mode: mode, motionDisabled: reduceMotion,
                             toggle: { [weak self] in self?.toggle(on: id) },
                             open: { [weak self] in self?.open(on: id) },
                             close: { [weak self] in self?.close(on: id) },
                             settings: { [weak self] in
                                 self?.close(on: id)
                                 self?.context?.openSettings(paneID: NotchFeature.settingsPaneID)
                             })
        surface.canvas.present(AnyView(view), size: geometry.frame(mode: mode).size, mode: mode,
                               animated: !reduceMotion && (!relocating || !surface.panel.isVisible))
        surface.panel.orderFrontRegardless()
        updatePointer(on: id)
    }

    private func updatePointer(on id: String) {
        guard !rendersOffscreen, let surface = surfaces[id], surface.panel.isVisible else { return }
        // Keep the matching mouse-up/drag in the same panel, even if the pointer crosses the mask.
        guard !surface.panel.isHandlingPointer else { return }
        let point = surface.canvas.convert(surface.panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = surface.canvas.containsSurface(point)
        if surface.panel.ignoresMouseEvents == inside { surface.panel.ignoresMouseEvents = !inside }
        if inside != surface.pointerInside {
            surface.pointerInside = inside
            hover(inside, on: id)
        }
    }

    func clickedOutside(window: NSWindow?) {
        guard trackingMenus == 0 else { return }
        for (id, surface) in surfaces where surface.session.presentation.mode == .expanded
            && !surface.session.presentation.isPinned && surface.panel !== window { close(on: id) }
    }

    private func installMonitors() {
        guard monitors.isEmpty, !rendersOffscreen else { return }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { if let self { for id in Array(self.surfaces.keys) { self.updatePointer(on: id) } } }
            return event
        }) { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { if let self { for id in Array(self.surfaces.keys) { self.updatePointer(on: id) } } }
        }) { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clickedOutside(window: event.window) }
            return event
        }) { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside(window: nil) }
        }) { monitors.append(token) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
    }

    private func removeSurfaces() {
        surfaces.values.forEach { $0.dispose() }; surfaces.removeAll()
        removeMonitors()
        trackingMenus = 0
    }
}
