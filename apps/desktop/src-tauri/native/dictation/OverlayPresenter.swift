// Ported from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import AppKit
import SwiftUI

@MainActor
final class OverlayPresenter {
    private weak var appState: DictationController?
    private let panel: NSPanel
    private let rootView: NSView
    private let hosting: NSHostingView<AnyView>
    private let nativeGlassView: NSView?

    init(appState: DictationController) {
        self.appState = appState
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        rootView = NSView(frame: NSRect(x: 0, y: 0, width: 188, height: 74))

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 12, y: 12, width: 164, height: 50))
            // clear 스타일의 실제 배경 굴절을 가리지 않도록 별도 틴트를 두지 않습니다.
            // 굴절 레이어만 낮은 불투명도로 합성하고 파형과 가장자리 반사광은 별도
            // 호스팅 뷰에 선명하게 그려, 흐린 아크릴 대신 투명한 유리로 보이게 합니다.
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
            rootView.addSubview(hosting)
        } else {
            nativeGlassView = nil
            rootView.addSubview(hosting)
        }

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 188, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // NSWindow의 기본 그림자는 투명한 캡슐이 아니라 사각 창 전체를 기준으로
        // 그려져 검은 네모처럼 보입니다. 재질과 외곽선은 SwiftUI에서만 그립니다.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
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
        guard let appState else { return }
        let contentWidth: CGFloat
        switch appState.overlayPreviewPhase ?? appState.phase {
        case "recording":
            contentWidth = (appState.overlaySettings.showRecordingShortcutHints ?? true)
                ? min(440, 150 + CGFloat(appState.recordingHints.count) * 90)
                : 164
        case "transcribing", "processing":
            contentWidth = (appState.overlaySettings.showTranscriptionStatus ?? true) ? 220 : 164
        default: contentWidth = 164
        }
        configureSurface(contentSize: NSSize(width: contentWidth, height: 50))
        hosting.rootView = AnyView(
            DictationOverlayView(message: nil, usesNativeGlass: nativeGlassView != nil)
                .environmentObject(appState)
                .environment(\.locale, Locale(identifier: appState.language.english ? "en" : "ko"))
        )
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func showToast(_ message: String) {
        guard let appState else { return }
        configureSurface(contentSize: NSSize(width: 330, height: 58))
        hosting.rootView = AnyView(
            DictationOverlayView(message: message, usesNativeGlass: nativeGlassView != nil)
                .environmentObject(appState)
                .environment(\.locale, Locale(identifier: appState.language.english ? "en" : "ko"))
        )
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        // Release TimelineViews while hidden; orderOut alone retains their update loops.
        hosting.rootView = AnyView(EmptyView())
    }

    private func configureSurface(contentSize: NSSize) {
        let panelSize = NSSize(width: contentSize.width + 24, height: contentSize.height + 24)
        panel.setContentSize(panelSize)
        rootView.frame = NSRect(origin: .zero, size: panelSize)

        if #available(macOS 26.0, *), let glass = nativeGlassView as? NSGlassEffectView {
            glass.frame = NSRect(origin: NSPoint(x: 12, y: 12), size: contentSize)
            glass.cornerRadius = contentSize.height / 2
            glass.layer?.shadowPath = CGPath(
                roundedRect: glass.bounds,
                cornerWidth: contentSize.height / 2,
                cornerHeight: contentSize.height / 2,
                transform: nil
            )
            hosting.frame = glass.frame
        } else {
            hosting.frame = rootView.bounds
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + max(76, frame.height * 0.14)
        )
        panel.setFrameOrigin(origin)
    }
}
