import AppKit

/// Small screen diagrams for window commands, as in the Tauri app (`.window-layout-icon`): a 25×19 rounded
/// screen with a faint fill and border, and the target region in blue. The region comes from the same geometry
/// the commands apply. Moves and display changes show an arrow instead; Restore shows an outlined window.
/// Colors resolve at draw time, so one image serves light and dark appearances.
@MainActor
enum WindowLayoutIcon {
    private static var cache: [String: NSImage] = [:]
    /// `#4ba7f4`, the layout fill of the Tauri app.
    static let fill = NSColor(srgbRed: 0x4B / 255.0, green: 0xA7 / 255.0, blue: 0xF4 / 255.0, alpha: 1)

    static func image(for layout: WindowLayout, size: CGFloat = 28) -> NSImage {
        let key = "\(layout.rawValue)-\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { bounds in
            draw(layout, in: bounds)
            return true
        }
        cache[key] = image
        return image
    }

    private static func draw(_ layout: WindowLayout, in bounds: CGRect) {
        // 25×19 at the 27 pt glyph size of the settings table; scaled for other sizes.
        let scale = bounds.width / 27
        let width = 25 * scale, height = 19 * scale
        let screen = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let outline = NSBezierPath(roundedRect: screen.insetBy(dx: 0.5, dy: 0.5), xRadius: 4 * scale, yRadius: 4 * scale)
        (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.03)).setFill()
        outline.fill()
        (dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let work = screen.insetBy(dx: 3 * scale, dy: 3 * scale)
        if let glyph = glyph(for: layout) {
            let configuration = NSImage.SymbolConfiguration(pointSize: height * 0.48, weight: .semibold)
                .applying(.init(paletteColors: [fill]))
            guard let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            let size = symbol.size
            symbol.draw(in: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        if layout == .restorePreviousLayout {
            let window = screen.insetBy(dx: 4 * scale + 0.5, dy: 4 * scale + 0.5)
            fill.setStroke()
            let path = NSBezierPath(rect: window)
            path.lineWidth = 1
            path.stroke()
            return
        }
        let current = CGRect(x: work.minX + work.width * 0.3, y: work.minY + work.height * 0.25,
                             width: work.width * 0.4, height: work.height * 0.5)
        let region = WindowGeometry.targetRect(layout, workArea: work, current: current)
        fill.setFill()
        NSBezierPath(rect: region.integralWithin(scale: NSScreen.main?.backingScaleFactor ?? 2)).fill()
    }

    private static func glyph(for layout: WindowLayout) -> String? {
        switch layout {
        case .nextDisplay: "arrow.right.to.line"
        case .previousDisplay: "arrow.left.to.line"
        case .moveLeft: "arrow.left"
        case .moveRight: "arrow.right"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        default: nil
        }
    }
}

private extension CGRect {
    /// Snaps to device pixels so thin fills stay crisp.
    func integralWithin(scale: CGFloat) -> CGRect {
        CGRect(x: (minX * scale).rounded() / scale, y: (minY * scale).rounded() / scale,
               width: max(1 / scale, (width * scale).rounded() / scale), height: max(1 / scale, (height * scale).rounded() / scale))
    }
}
