import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import PrismNotch

@MainActor
struct NotchMotionTests {
    @Test func firstPresentationRevealsDownFromTheScreenEdge() async throws {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 512, height: 354),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let canvas = NotchCanvas(frame: CGRect(x: 0, y: 0, width: 512, height: 354))
        window.contentView = canvas
        window.orderFrontRegardless()
        defer { canvas.clear(); window.orderOut(nil) }
        canvas.present(AnyView(Text("Timer").frame(maxWidth: .infinity, maxHeight: .infinity)),
                       size: CGSize(width: 480, height: 330), mode: .expanded, animated: true)
        CATransaction.flush()
        let motion = try #require(canvas.motion)
        #expect(motion.from == CGSize(width: 480, height: 1))
        let finalFrame = canvas.contentFrame
        // CI may not composite an invisible off-screen panel before the animation ends.
        // Verify the installed Core Animation frames instead of scheduler/display timing.
        let reveal = try #require(canvas.layer?.mask?.animation(forKey: "morph") as? CAKeyframeAnimation)
        let revealPaths = try #require(reveal.values as? [CGPath])
        #expect(revealPaths.contains { $0.boundingBoxOfPath.height > 1 && $0.boundingBoxOfPath.height < 330 })
        #expect(revealPaths.allSatisfy { abs($0.boundingBoxOfPath.width - 480) < 0.01 })
        #expect(canvas.visiblePath?.boundingBoxOfPath.minY == 0)
        #expect(canvas.contentFrame == finalFrame)
        // Reduced motion must skip both the reveal and the content translation.
        canvas.clear()
        canvas.present(AnyView(Text("Timer")), size: CGSize(width: 480, height: 330), mode: .expanded, animated: false)
        #expect(canvas.motion == nil)
        #expect(canvas.host?.layer?.animationKeys()?.isEmpty ?? true)
    }

    @Test func interruptedSpringCarriesItsPositionAndVelocity() {
        let flight = NotchMotion(from: CGSize(width: 200, height: 34), to: CGSize(width: 480, height: 330), began: 10)
        let current = flight.sample(at: 10.08)
        let reverse = NotchMotion(from: current.size, to: flight.from, velocity: current.velocity, began: 10.08)
        #expect(reverse.sample(at: 10.08).size == current.size)
        #expect(abs(reverse.sample(at: 10.08).velocity.height - current.velocity.height) < 0.001)
        #expect(reverse.sample(at: 11).size == flight.from)
    }

    @Test func nativeMaskMovesWhileWindowAndRealContentStayFixed() async throws {
        _ = NSApplication.shared
        let model = NotchModel(widgets: [], initial: NotchPreferences()) { _ in }
        let geometry = NotchGeometry(screenFrame: CGRect(x: -20000, y: -20000, width: 1512, height: 982), cameraWidth: 180, topInset: 34)
        let window = NSPanel(contentRect: geometry.stageFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let canvas = NotchCanvas(frame: CGRect(origin: .zero, size: geometry.stageFrame.size))
        window.contentView = canvas
        window.orderFrontRegardless()
        defer { canvas.clear(); window.orderOut(nil) }
        func present(_ mode: NotchPresentation.Mode, animated: Bool) {
            canvas.present(AnyView(NotchView(model: model, geometry: geometry, mode: mode)),
                           size: geometry.frame(mode: mode).size, mode: mode, animated: animated)
            CATransaction.flush()
        }
        present(.compact, animated: false)
        try await Task.sleep(for: .milliseconds(80))
        let windowFrame = window.frame
        present(.expanded, animated: true)
        let contentFrame = try #require(canvas.contentFrame)
        #expect(contentFrame.size == geometry.frame(mode: .expanded).size)
        let morph = try #require(canvas.layer?.mask?.animation(forKey: "morph") as? CAKeyframeAnimation)
        let paths = try #require(morph.values as? [CGPath])
        #expect(paths.contains { $0.boundingBoxOfPath.height > 34 && $0.boundingBoxOfPath.height < 330 })
        #expect(paths.first?.boundingBoxOfPath.size == geometry.frame(mode: .compact).size)
        let finalSize = try #require(paths.last?.boundingBoxOfPath.size)
        #expect(abs(finalSize.width - 480) < 0.01 && abs(finalSize.height - 330) < 0.01)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            #expect(window.frame == windowFrame)
            #expect(canvas.contentFrame == contentFrame)
            #expect(abs((canvas.visiblePath?.boundingBoxOfPath.midX ?? 0) - canvas.bounds.midX) < 1)
            #expect(canvas.visiblePath?.boundingBoxOfPath.minY == 0)
        }
        present(.compact, animated: true)
        try await Task.sleep(for: .milliseconds(650))
        #expect(abs(canvas.visibleSize.width - 200) < 0.01)
        #expect(abs(canvas.visibleSize.height - 34) < 0.01)
        #expect(window.frame == windowFrame)
        #expect(!canvas.containsSurface(CGPoint(x: 30, y: 180)))
        #expect(canvas.containsSurface(CGPoint(x: canvas.bounds.midX, y: 10)))
        present(.expanded, animated: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(canvas.motion == nil)
        #expect(canvas.visibleSize == geometry.frame(mode: .expanded).size)
        #expect(canvas.contentOpacity == 1)
        // Readable outgoing content must disappear before the sides can crop it.
        present(.compact, animated: true)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(10))
            if canvas.departingContentOpacity > 0.01 {
                #expect(canvas.visibleSize.width >= 479)
            }
        }
        canvas.clear()
        #expect(canvas.host == nil)
        #expect(canvas.motion == nil)
        #expect(!canvas.containsSurface(CGPoint(x: canvas.bounds.midX, y: 10)))
    }
}
