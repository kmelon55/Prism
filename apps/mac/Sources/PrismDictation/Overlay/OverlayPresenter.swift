// Ported from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit
import SwiftUI

/// A nonactivating, click-through capsule near the bottom of the active screen. It never takes focus,
/// so the app being dictated into stays key.
@MainActor
final class OverlayPresenter {
    private weak var controller: DictationController?
    private let panel: NSPanel
    private let rootView: NSView
    private let hosting: NSHostingView<AnyView>
    private let nativeGlassView: NSView?

    init(controller: DictationController) {
        self.controller = controller
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        rootView = NSView(frame: NSRect(x: 0, y: 0, width: 188, height: 74))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 12, y: 12, width: 164, height: 50))
            // Clear glass with no tint keeps real refraction; the waveform and edge highlights draw sharply in a
            // separate sibling hosting view so the capsule reads as transparent glass, not frosted acrylic.
            glass.style = .clear
            glass.tintColor = nil
            glass.alphaValue = 0.50
            glass.cornerRadius = 25
            let effectContent = NSView(frame: glass.bounds)
            effectContent.autoresizingMask = [.width, .height]
            glass.contentView = effectContent
            glass.wantsLayer = true
            glass.layer?.masksToBounds = false
            glass.layer?.shadowColor = NSColor.black.cgColor
            glass.layer?.shadowOpacity = 0.10
            glass.layer?.shadowRadius = 7
            glass.layer?.shadowOffset = NSSize(width: 0, height: -2)
            nativeGlassView = glass
            rootView.addSubview(glass)
        } else {
            nativeGlassView = nil
        }
        rootView.addSubview(hosting)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 188, height: 74), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The window shadow would follow the rectangular window, not the capsule. SwiftUI draws the edge instead.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.isOpaque = false
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView
    }

    func show() {
        guard let controller else { return }
        configureSurface(contentSize: NSSize(width: Self.contentWidth(for: controller), height: 50))
        hosting.rootView = AnyView(DictationOverlayView(controller: controller, message: nil, usesNativeGlass: nativeGlassView != nil))
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func showToast(_ message: String) {
        guard let controller else { return }
        configureSurface(contentSize: NSSize(width: 330, height: 58))
        hosting.rootView = AnyView(DictationOverlayView(controller: controller, message: message, usesNativeGlass: nativeGlassView != nil))
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        // Release TimelineViews while hidden; orderOut alone keeps their update loops alive.
        hosting.rootView = AnyView(EmptyView())
    }

    static func contentWidth(for controller: DictationController) -> CGFloat {
        switch controller.displayedPhase {
        case .recording:
            controller.showRecordingShortcutHints ? min(440, 150 + CGFloat(controller.recordingHints.count) * 90) : 164
        case .transcribing, .processing:
            controller.showTranscriptionStatus ? 220 : 164
        default: 164
        }
    }

    private func configureSurface(contentSize: NSSize) {
        let panelSize = NSSize(width: contentSize.width + 24, height: contentSize.height + 24)
        panel.setContentSize(panelSize)
        rootView.frame = NSRect(origin: .zero, size: panelSize)
        if #available(macOS 26.0, *), let glass = nativeGlassView as? NSGlassEffectView {
            glass.frame = NSRect(origin: NSPoint(x: 12, y: 12), size: contentSize)
            glass.cornerRadius = contentSize.height / 2
            glass.layer?.shadowPath = CGPath(roundedRect: glass.bounds, cornerWidth: contentSize.height / 2,
                                             cornerHeight: contentSize.height / 2, transform: nil)
            hosting.frame = glass.frame
        } else {
            hosting.frame = rootView.bounds
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + max(76, frame.height * 0.14)))
    }
}
