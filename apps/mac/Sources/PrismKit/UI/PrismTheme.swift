import AppKit
import SwiftUI

/// The neutral glass palette of the Tauri app (`surfaces.css`): monochrome text, faint lines and a soft
/// selection gradient, in dark and light variants.
public enum PrismTheme {
    public static let text = dynamic(dark: 0xF3F3F3, light: 0x242424)
    public static let textSecondary = dynamic(dark: 0xC2C2C2, light: 0x585858)
    public static let textMuted = dynamic(dark: 0x999999, light: 0x737373)
    public static let accent = dynamic(dark: 0xCFCFCF, light: 0x606060)
    public static let accentStrong = dynamic(dark: 0xF0F0F0, light: 0x303030)
    public static let surface = dynamic(dark: 0xFFFFFF, darkAlpha: 0x05, light: 0x000000, lightAlpha: 0x03)
    public static let surfaceStrong = dynamic(dark: 0xFFFFFF, darkAlpha: 0x0D, light: 0x000000, lightAlpha: 0x07)
    public static let surfaceSelected = dynamic(dark: 0xFFFFFF, darkAlpha: 0x16, light: 0x000000, lightAlpha: 0x0C)
    public static let line = dynamic(dark: 0xFFFFFF, darkAlpha: 0x05, light: 0x000000, lightAlpha: 0x04)
    public static let lineStrong = dynamic(dark: 0xFFFFFF, darkAlpha: 0x0B, light: 0x000000, lightAlpha: 0x09)
    /// Separators between table rows; a touch stronger than `line` so they survive over glass.
    public static let separator = dynamic(dark: 0xFFFFFF, darkAlpha: 0x0A, light: 0x000000, lightAlpha: 0x0A)
    /// Inputs and the sidebar search field: an opaque well (`--panel` in the settings window).
    public static let field = dynamic(dark: 0x292929, light: 0xFFFFFF)
    public static let control = dynamic(dark: 0xFFFFFF, darkAlpha: 0x0D, light: 0xFFFFFF, lightAlpha: 0x80)
    public static let controlHover = dynamic(dark: 0xFFFFFF, darkAlpha: 0x18, light: 0xFFFFFF, lightAlpha: 0xC0)
    public static let danger = dynamic(dark: 0xF07A7A, light: 0xC2413B)
    public static let success = dynamic(dark: 0x8BD3A0, light: 0x2F8A4C)
    public static let warning = dynamic(dark: 0xE8C27A, light: 0x9A6A12)
    public static let panel = dynamic(dark: 0x292929, light: 0xFAFAFA)
    public static let keyCap = dynamic(dark: 0xFFFFFF, darkAlpha: 0x0E, light: 0x000000, lightAlpha: 0x08)

    /// The selected row: a faint vertical gradient rather than a flat fill.
    public static let selection = LinearGradient(
        colors: [dynamic(dark: 0xFFFFFF, darkAlpha: 0x17, light: 0x000000, lightAlpha: 0x09),
                 dynamic(dark: 0xFFFFFF, darkAlpha: 0x0D, light: 0x000000, lightAlpha: 0x06)],
        startPoint: .top, endPoint: .bottom
    )

    /// The shell tint painted over the glass; its alpha is the user's background opacity.
    public static func shellTint(opacity: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance)
                ? NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 24 / 255, alpha: opacity)
                : NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: opacity)
        }
    }

    public static let cornerRadius: CGFloat = 18
    public static let defaultBackgroundOpacity = 0.64

    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public static func dynamic(dark: UInt32, darkAlpha: UInt8 = 0xFF, light: UInt32, lightAlpha: UInt8 = 0xFF) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDark(appearance) ? color(dark, darkAlpha) : color(light, lightAlpha)
        })
    }

    private static func color(_ rgb: UInt32, _ alpha: UInt8) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: CGFloat(alpha) / 255)
    }
}

/// The soft reflection (`--glass-light`), the pointer-lit face and the spectral edge drawn over the glass shell.
public struct PrismShellOverlay: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = PrismTheme.cornerRadius) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(
                stops: [.init(color: .white.opacity(dark ? 0.028 : 0.2), location: 0), .init(color: .clear, location: 0.42)],
                startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)
            ))
            PrismReflections(cornerRadius: cornerRadius)
        }
        .allowsHitTesting(false)
    }
}

/// The Prism logo: an obsidian prism with a silver cut and a narrow band of dispersed light (`PrismMark.tsx`).
public struct PrismMark: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 32
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func gradient(_ stops: [(UInt32, CGFloat)], from: CGPoint, to: CGPoint) -> GraphicsContext.Shading {
                .linearGradient(Gradient(stops: stops.map { .init(color: Color(hex: $0.0), location: $0.1) }),
                                startPoint: from, endPoint: to)
            }
            let body = Path(roundedRect: CGRect(x: 0.5 * s, y: 0.5 * s, width: 31 * s, height: 31 * s), cornerRadius: 8.5 * s)
            context.fill(body, with: gradient([(0x303236, 0), (0x111214, 0.48), (0x050506, 1)], from: point(4, 2), to: point(27, 32)))
            context.stroke(body, with: .color(.white.opacity(0.18)), lineWidth: s)
            let cut = gradient([(0xFFFFFF, 0), (0xD6DBDE, 0.36), (0x6A6E76, 0.65), (0xC5CBCF, 1)], from: point(8, 8), to: point(25, 26))
            var prism = Path()
            prism.addLines([point(16, 5.7), point(27, 25), point(5, 25)])
            prism.closeSubpath()
            context.fill(prism, with: .color(Color(hex: 0x08090B)))
            context.stroke(prism, with: cut, style: StrokeStyle(lineWidth: 1.15 * s, lineJoin: .round))
            var spectrum = Path()
            spectrum.addLines([point(16, 5.7), point(19.2, 23.1), point(27, 25)])
            spectrum.closeSubpath()
            context.opacity = 0.85
            context.fill(spectrum, with: gradient([(0xF1A1A0, 0), (0xEBC58F, 0.18), (0xE5DEA0, 0.34), (0xA1D6B7, 0.5),
                                                   (0x8FCBE9, 0.67), (0xA2B2E8, 0.83), (0xC2A7DD, 1)],
                                                  from: point(21, 14), to: point(25, 25)))
            var face = Path()
            face.addLines([point(16, 5.7), point(19.2, 23.1), point(5, 25)])
            face.closeSubpath()
            context.opacity = 0.12
            context.fill(face, with: cut)
            context.opacity = 1
            var ray = Path()
            ray.addLines([point(3.5, 18.4), point(13, 15.7), point(19.2, 23.1)])
            context.stroke(ray, with: .color(.white.opacity(0.88)), style: StrokeStyle(lineWidth: 0.8 * s, lineCap: .round, lineJoin: .round))
            var exit = Path()
            exit.addLines([point(19.2, 23.1), point(27, 25)])
            context.stroke(exit, with: .color(.white.opacity(0.42)), lineWidth: 0.65 * s)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

public extension NSView {
    /// Liquid glass (macOS 26) or a behind-window blur on older systems, with the shell tint on top, clipped to
    /// the Prism corner radius. Content goes in the returned view's `contentView`.
    @MainActor
    static func prismGlassBackground(cornerRadius: CGFloat = PrismTheme.cornerRadius, opacity: Double) -> PrismGlassView {
        PrismGlassView(cornerRadius: cornerRadius, opacity: opacity)
    }
}

@MainActor
public final class PrismGlassView: NSView {
    public let contentView = NSView()
    private let tint = NSView()
    private var glass = NSView()
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat, opacity: Double) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .clear
            effect.cornerRadius = cornerRadius
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .active
            glass = effect
        }
        tint.wantsLayer = true
        for view in [glass, tint, contentView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        setOpacity(opacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setOpacity(_ opacity: Double) {
        tintOpacity = opacity
        updateTint()
    }

    /// The Tauri "Background blur" (0...32 pt). The glass blur radius is an internal Core Animation filter input,
    /// so it is feature-detected and AppKit's own radius stays in place when the input is missing. Zero removes the
    /// glass and leaves only the tint, as Tauri did.
    public func setBlurRadius(_ radius: Double) {
        blurRadius = min(max(radius, 0), 32)
        glass.isHidden = blurRadius == 0
        scheduleBlurRefresh()
    }

    private var blurRadius: Double?
    private var displayLink: CADisplayLink?
    private var watchUntil = Date.distantPast

    /// AppKit rebuilds the backdrop filters with its own radius when the window appears, resizes or changes level,
    /// sometimes a few frames after the change. The radius is reapplied on every frame for a short while after each
    /// such change, so the default never shows for more than a frame.
    public func scheduleBlurRefresh() {
        guard blurRadius != nil else { return }
        watchUntil = Date().addingTimeInterval(0.8)
        reapplyBlur()
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired() {
        reapplyBlur()
        if Date() > watchUntil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func reapplyBlur() {
        guard let radius = blurRadius, let layer = glass.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.apply(radius: radius, to: layer)
        CATransaction.commit()
    }

    @discardableResult
    static func apply(radius: Double, to layer: CALayer) -> Bool {
        var changed = false
        if var filters = layer.filters, !filters.isEmpty {
            var replaced = false
            for (index, filter) in filters.enumerated() {
                guard let object = filter as? NSObject, object.responds(to: NSSelectorFromString("inputKeys")),
                      let keys = object.value(forKey: "inputKeys") as? [String] else { continue }
                guard let key = ["inputBlurRadius", "inputRadius"].first(where: keys.contains) else { continue }
                if let current = object.value(forKey: key) as? NSNumber, abs(current.doubleValue - radius) < .ulpOfOne { continue }
                // Mutating the live filter does not invalidate the render cache; replace it with an updated copy.
                guard let copy = object.copy() as? NSObject else { continue }
                copy.setValue(NSNumber(value: radius), forKey: key)
                filters[index] = copy
                replaced = true
            }
            if replaced {
                layer.filters = filters
                changed = true
            }
        }
        for child in layer.sublayers ?? [] {
            changed = apply(radius: radius, to: child) || changed
        }
        return changed
    }

    public override func layout() {
        super.layout()
        scheduleBlurRefresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        scheduleBlurRefresh()
    }

    private var windowObservers: [NSObjectProtocol] = []

    /// AppKit builds the backdrop filters only once the window is actually on screen, and rebuilds them when it
    /// comes back. A window created at launch and shown later would otherwise keep the default radius, so the
    /// radius is reapplied whenever the window becomes visible, key or resized.
    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleBlurRefresh() }
            }
        }
    }

    private var tintOpacity = PrismTheme.defaultBackgroundOpacity

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = PrismTheme.shellTint(opacity: tintOpacity).cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }
}
