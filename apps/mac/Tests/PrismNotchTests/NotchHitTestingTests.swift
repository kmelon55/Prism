import AppKit
import SwiftUI
import Testing
@testable import PrismNotch

@MainActor
struct NotchHitTestingTests {
    @Test func compactHeaderHitTestingConvertsFromUnflippedSuperview() throws {
        _ = NSApplication.shared
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let canvas = NotchCanvas(frame: CGRect(x: 30, y: 20, width: 512, height: 354))
        parent.addSubview(canvas)
        canvas.present(AnyView(Text("Open").frame(maxWidth: .infinity, maxHeight: .infinity)),
                       size: CGSize(width: 200, height: 34), mode: .compact, animated: false)
        defer { canvas.clear() }
        #expect(canvas.host?.acceptsFirstMouse(for: nil) == true)
        let header = CGPoint(x: canvas.bounds.midX, y: 17)
        #expect(canvas.containsSurface(header))
        let inParent = canvas.convert(header, to: parent)
        #expect(canvas.hitTest(inParent) != nil)
        let transparent = canvas.convert(CGPoint(x: 30, y: 200), to: parent)
        #expect(canvas.hitTest(transparent) == nil)

        canvas.present(AnyView(Text("Timer controls").frame(maxWidth: .infinity, maxHeight: .infinity)),
                       size: CGSize(width: 480, height: 330), mode: .expanded, animated: false)
        // The lower controls must also receive clicks through the flipped canvas.
        let controls = canvas.convert(CGPoint(x: 430, y: 250), to: parent)
        #expect(canvas.hitTest(controls) != nil)
        let outside = canvas.convert(CGPoint(x: 5, y: 250), to: parent)
        #expect(canvas.hitTest(outside) == nil)
    }
}
