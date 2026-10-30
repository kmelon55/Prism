import AppKit
import Observation
import SwiftUI

// The Tauri glass optics (`surfaces.css` + `interaction/prismReflections.css`, driven by `useGlassRefraction.ts`):
// a light that follows the pointer anywhere on screen, lighting the shell's face and splitting into a narrow
// spectrum where it meets the edge. Opening the palette sweeps the light clockwise around the edge once.

/// The shared light source. Shell overlays attach while visible; the pointer is polled only then.
@MainActor
@Observable
public final class PrismLight {
    public static let shared = PrismLight()

    /// The lit point on the shell, in unit coordinates (y down).
    public private(set) var point = CGPoint(x: 0.32, y: 0.22)
    /// Where the spectrum's white core sits, in CSS conic degrees (0 = top, clockwise).
    public private(set) var angle: Double = 12

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var attached = 0
    @ObservationIgnored private var target = CGPoint(x: 0.32, y: 0.22)
    @ObservationIgnored private var sweep: (started: Date, end: Double)?

    static let sweepDuration = 1.5
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "reduceMotion")
    }

    func attach() {
        attached += 1
        if attached == 1 { start() }
    }

    func detach() {
        attached = max(0, attached - 1)
        if attached == 0 { stop() }
    }

    /// The arrival sweep: from the bottom edge clockwise to the pointer's direction, easing out over 1.5 s.
    public func playOpeningSweep() {
        guard !Self.isReduced, UserDefaults.standard.object(forKey: "openingLightAnimation") as? Bool ?? true else { return }
        readPointer()
        var travel = Self.clockwise(Self.direction(target) - 180)
        if travel < 30 { travel += 360 }
        sweep = (Date(), 180 + travel)
        angle = 180
        point = CGPoint(x: 0.5, y: 0.72)
        start()
    }

    private func start() {
        guard timer == nil, attached > 0, !Self.isReduced else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        sweep = nil
    }

    private var frame = 0

    private func tick() {
        frame += 1
        // Pointer reads at 30 Hz like Tauri; the sweep animates every frame.
        if frame % 2 == 0 || sweep != nil { readPointer() }
        if let sweep {
            let progress = min(1, max(0, Date().timeIntervalSince(sweep.started) / Self.sweepDuration))
            let eased = 1 - pow(1 - progress, 3)
            let degrees = max(angle, 180 + (sweep.end - 180) * eased)
            let start = 0.22
            let radius = start + (hypot(target.x - 0.5, target.y - 0.5) - start) * eased
            let radians = degrees * .pi / 180
            set(point: CGPoint(x: 0.5 + sin(radians) * radius, y: 0.5 - cos(radians) * radius), angle: degrees)
            if progress >= 1 { self.sweep = nil }
            return
        }
        let degrees = angle + Self.clockwise(Self.direction(target) - angle + 180) - 180
        set(point: target, angle: degrees)
    }

    private func set(point: CGPoint, angle: Double) {
        if abs(point.x - self.point.x) > 0.0005 || abs(point.y - self.point.y) > 0.0005 { self.point = point }
        if abs(angle - self.angle) > 0.05 { self.angle = angle }
    }

    /// The pointer relative to its display, clamped like Tauri so the light never sits on a corner.
    private func readPointer() {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main,
              screen.frame.width > 0, screen.frame.height > 0 else { return }
        let x = (cursor.x - screen.frame.minX) / screen.frame.width
        let y = 1 - (cursor.y - screen.frame.minY) / screen.frame.height
        target = CGPoint(x: min(max(x, 0.12), 0.88), y: min(max(y, 0.08), 0.72))
    }

    static func direction(_ point: CGPoint) -> Double {
        atan2(point.y - 0.5, point.x - 0.5) * 180 / .pi + 90
    }

    static func clockwise(_ angle: Double) -> Double {
        (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// The face light and the spectral edge, drawn over the shell's glass.
struct PrismReflections: View {
    let cornerRadius: CGFloat
    var light = PrismLight.shared

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let point = light.point
            let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
            // `circle at x y` sizes to the farthest corner.
            let reach = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
                .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 1
            ZStack {
                shape.fill(RadialGradient(stops: [
                    .init(color: .white.opacity(0x1B / 255), location: 0),
                    .init(color: .white.opacity(0x06 / 255), location: 0.32),
                    .init(color: .clear, location: 0.56),
                ], center: UnitPoint(x: point.x, y: point.y), startRadius: 0, endRadius: reach))
                .opacity(0.65)
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.045), location: 0),
                    .init(color: .white.opacity(0.008), location: 0.34),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.012), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .opacity(0.65)
                shape.strokeBorder(Color.white.opacity(0x12 / 255), lineWidth: 1.05)
                shape.strokeBorder(AngularGradient(stops: Self.spectrum, center: .center,
                                                   angle: .degrees(light.angle - 45 - 90)), lineWidth: 1.05)
            }
        }
        .allowsHitTesting(false)
        .onAppear { light.attach() }
        .onDisappear { light.detach() }
    }

    /// `--reflection-edge` .2 and `--reflection-highlight` .4, the Tauri defaults.
    static let spectrum: [Gradient.Stop] = {
        let band = 0.22 + 0.2 * 0.2
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
        return [
            .init(color: .clear, location: 0), .init(color: .clear, location: 0.065),
            .init(color: rgb(255, 76, 68, band), location: 0.08),
            .init(color: rgb(255, 155, 50, band), location: 0.095),
            .init(color: rgb(255, 221, 80, band), location: 0.11),
            .init(color: rgb(73, 215, 133, band), location: 0.12),
            .init(color: rgb(234, 250, 255, 0.4), location: 0.125),
            .init(color: rgb(58, 166, 255, band), location: 0.135),
            .init(color: rgb(85, 100, 225, band), location: 0.15),
            .init(color: rgb(170, 100, 225, band), location: 0.165),
            .init(color: .clear, location: 0.215), .init(color: .clear, location: 0.57),
            .init(color: .white.opacity(0.4 * 0.35), location: 0.62),
            .init(color: .clear, location: 0.69), .init(color: .clear, location: 1),
        ]
    }()
}

// MARK: Prism highlights

/// The "Prism highlights" preference: soft refracted color on selected controls (`settingsPolish.css`).
public enum PrismHighlights {
    public static let key = "prismHighlights"

    static let pastel = LinearGradient(stops: [
        .init(color: Color(hex: 0xC4A7AB), location: 0), .init(color: Color(hex: 0xCCB792), location: 0.17),
        .init(color: Color(hex: 0xC7C197), location: 0.32), .init(color: Color(hex: 0xA4C4B4), location: 0.47),
        .init(color: Color(hex: 0x9BBCD1), location: 0.63), .init(color: Color(hex: 0xA5ACD2), location: 0.80),
        .init(color: Color(hex: 0xBDA6C8), location: 1),
    ], startPoint: UnitPoint(x: 0, y: 0.3), endPoint: UnitPoint(x: 1, y: 0.7))

    static let refraction = LinearGradient(stops: [
        .init(color: Color(hex: 0xD4A5AB).opacity(0.4), location: 0), .init(color: Color(hex: 0xD9BC98).opacity(0.4), location: 0.17),
        .init(color: Color(hex: 0xD4CE9F).opacity(0.4), location: 0.32), .init(color: Color(hex: 0xA7CBB8).opacity(0.4), location: 0.47),
        .init(color: Color(hex: 0x9DC2D8).opacity(0.4), location: 0.63), .init(color: Color(hex: 0xA7B2D8).opacity(0.4), location: 0.80),
        .init(color: Color(hex: 0xC0ACD4).opacity(0.4), location: 1),
    ], startPoint: UnitPoint(x: 0, y: 0.3), endPoint: UnitPoint(x: 1, y: 0.7))

    static let edgeLight = LinearGradient(stops: [
        .init(color: Color(hex: 0xEF9C96).opacity(0.6), location: 0), .init(color: Color(hex: 0xE8BA88).opacity(0.6), location: 0.17),
        .init(color: Color(hex: 0xE5DA9B).opacity(0.6), location: 0.32), .init(color: Color(hex: 0xB1D7BB).opacity(0.6), location: 0.44),
        .init(color: Color(hex: 0xEDF7FF).opacity(0.73), location: 0.49), .init(color: Color(hex: 0x9AC9E5).opacity(0.6), location: 0.58),
        .init(color: Color(hex: 0xA6AFE2).opacity(0.6), location: 0.78), .init(color: Color(hex: 0xC4A6DF).opacity(0.6), location: 1),
    ], startPoint: UnitPoint(x: 0, y: 0.3), endPoint: UnitPoint(x: 1, y: 0.7))

    static let thumb = LinearGradient(stops: [
        .init(color: Color(hex: 0xC5A6A0), location: 0), .init(color: Color(hex: 0xCEC1A0), location: 0.28),
        .init(color: Color(hex: 0xB5C5B9), location: 0.48), .init(color: Color(hex: 0xA9BBC9), location: 0.70),
        .init(color: Color(hex: 0xB9ADC5), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let gloss = LinearGradient(stops: [
        .init(color: .white.opacity(0x16 / 255), location: 0), .init(color: .clear, location: 0.45),
        .init(color: .black.opacity(0x08 / 255), location: 1),
    ], startPoint: UnitPoint(x: 0.37, y: 0), endPoint: UnitPoint(x: 0.63, y: 1))
}

/// Paints the refracted face and edge on an active control when Prism highlights are on.
struct PrismHighlightModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    @AppStorage(PrismHighlights.key) private var enabled = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let on = enabled && active
        content.background {
            ZStack {
                shape.fill(PrismHighlights.gloss)
                shape.fill(PrismHighlights.refraction)
            }
            .opacity(on ? (colorScheme == .dark ? 0.55 : 0.5) : 0)
        }
        .overlay {
            shape.strokeBorder(PrismHighlights.edgeLight, lineWidth: 1).opacity(on ? 0.38 : 0).allowsHitTesting(false)
        }
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: on)
    }
}

public extension View {
    /// Prism highlights for a selected control (sidebar item, theme option, primary button).
    func prismHighlight(active: Bool = true, cornerRadius: CGFloat = 7) -> some View {
        modifier(PrismHighlightModifier(active: active, cornerRadius: cornerRadius))
    }
}

// MARK: Window dragging

/// A transparent strip that moves its window when dragged. Windows whose content has sliders or other drag
/// gestures must not be movable by their whole background; they put this behind headers instead.
public struct WindowDragArea: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView { DragView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
