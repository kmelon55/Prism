import AppKit
import QuartzCore
import SwiftUI

private final class NotchContentHost: NSHostingView<AnyView> {
    var receivesInput = true
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { receivesInput ? super.hitTest(point) : nil }
}

/// A fixed transparent window holds this stage. Core Animation morphs its mask, while SwiftUI
/// lays out each incoming page once at its final size. No window-resize or SwiftUI layout animation.
@MainActor
final class NotchCanvas: NSView {
    override var isFlipped: Bool { true }
    private let silhouette = CAShapeLayer()
    private(set) var host: NSHostingView<AnyView>?
    private var departing: NSHostingView<AnyView>?
    private(set) var targetSize = CGSize.zero
    private(set) var mode: NotchPresentation.Mode?
    private(set) var motion: NotchMotion?
    private var tick: Timer?
    private var finishDeparture: Task<Void, Never>?
    var onFrame: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = silhouette
        silhouette.fillColor = NSColor.black.cgColor
        appearance = NSAppearance(named: .darkAqua)
    }
    required init?(coder: NSCoder) { nil }

    var visiblePath: CGPath? {
        motion == nil ? silhouette.path : (silhouette.presentation()?.path ?? silhouette.path)
    }
    var visibleSize: CGSize { visiblePath?.boundingBoxOfPath.size ?? targetSize }
    var contentFrame: CGRect? { host?.frame }
    var contentOpacity: Float { host?.layer?.presentation()?.opacity ?? host?.layer?.opacity ?? 0 }
    var departingContentOpacity: Float { departing?.layer?.presentation()?.opacity ?? departing?.layer?.opacity ?? 0 }

    func containsSurface(_ point: CGPoint) -> Bool { visiblePath?.contains(point) ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        containsSurface(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    func path(for size: CGSize) -> CGPath {
        NotchOutline().path(in: CGRect(x: (bounds.width - size.width) / 2, y: 0,
                                      width: size.width, height: size.height)).cgPath
    }

    func present(_ content: AnyView, size: CGSize, mode nextMode: NotchPresentation.Mode, animated: Bool) {
        let changesSize = size != targetSize
        let changesPage = mode != nextMode
        let firstPresentation = targetSize == .zero
        let shouldAnimate = animated

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        silhouette.frame = bounds
        if changesPage || host == nil {
            finishDeparture?.cancel()
            departing?.removeFromSuperview()
            departing = host
            (departing as? NotchContentHost)?.receivesInput = false
            let incoming = NotchContentHost(rootView: content)
            incoming.sizingOptions = []
            incoming.wantsLayer = true
            addSubview(incoming)
            host = incoming
        } else {
            host?.rootView = content
        }
        // This frame is the destination size for the entire animation, including the first frame.
        host?.frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        host?.layoutSubtreeIfNeeded()
        // First-time SwiftUI layout can take a frame or more. Start the clock only after it is ready.
        let now = CACurrentMediaTime()
        let sampled = motion?.sample(at: now)
        // On first appearance reveal downwards from the screen edge at the final width.
        let start = sampled?.size ?? (firstPresentation ? CGSize(width: size.width, height: 1) : targetSize)
        let departingOpacity = departing?.layer?.presentation()?.opacity ?? departing?.layer?.opacity ?? 0
        let departureDelay = changesPage && size.height < start.height && departingOpacity > 0.05 ? 0.06 : 0
        targetSize = size
        mode = nextMode

        if changesSize || !shouldAnimate {
            silhouette.removeAnimation(forKey: "morph")
            silhouette.path = path(for: size)
            if shouldAnimate && changesSize {
                let flight = NotchMotion(from: start, to: size, velocity: sampled?.velocity ?? .zero, began: now + departureDelay)
                motion = flight
                let count = 68
                let animation = CAKeyframeAnimation(keyPath: "path")
                animation.values = (0...count).map { path(for: flight.sample(at: flight.began + NotchMotion.duration * Double($0) / Double(count)).size) }
                animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
                animation.duration = NotchMotion.duration
                animation.beginTime = flight.began
                animation.fillMode = .backwards
                animation.calculationMode = .linear
                silhouette.add(animation, forKey: "morph")
                startTicking()
            } else {
                motion = nil
                tick?.invalidate(); tick = nil
            }
        }
        if changesPage {
            if shouldAnimate {
                // Old content leaves before the silhouette gets too small. The new page is revealed
                // after the initial growth, so narrow masks never show squeezed or wrapped controls.
                if let departing {
                    let alpha = departing.layer?.presentation()?.opacity ?? departing.layer?.opacity ?? 1
                    departing.layer?.removeAllAnimations()
                    departing.layer?.opacity = 0
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = alpha; fade.toValue = 0; fade.duration = 0.06
                    departing.layer?.add(fade, forKey: "departure")
                }
                host?.layer?.opacity = 1
                let reveal = CAKeyframeAnimation(keyPath: "opacity")
                reveal.values = [0, 0, 1]
                reveal.keyTimes = [0, 0.46, 1]
                reveal.duration = nextMode == .compact ? 0.24 : 0.34
                host?.layer?.add(reveal, forKey: "arrival")
                // Only the silhouette moves. Translating the hosting layer would move the pixels
                // without moving AppKit's mouse coordinates for the buttons inside it.
                finishDeparture = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    self?.departing?.removeFromSuperview()
                    self?.departing = nil
                }
            } else {
                departing?.removeFromSuperview(); departing = nil
                host?.layer?.removeAllAnimations()
                host?.layer?.opacity = 1
            }
        }
        if !shouldAnimate {
            finishDeparture?.cancel()
            departing?.removeFromSuperview(); departing = nil
            host?.layer?.removeAllAnimations()
            host?.layer?.opacity = 1
        }
        CATransaction.commit()
        onFrame?()
    }

    private func startTicking() {
        guard tick == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let motion = self.motion, CACurrentMediaTime() >= motion.began + NotchMotion.duration {
                    self.motion = nil
                    self.tick?.invalidate(); self.tick = nil
                }
                self.onFrame?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    func clear() {
        tick?.invalidate(); tick = nil
        finishDeparture?.cancel(); finishDeparture = nil
        motion = nil
        silhouette.removeAllAnimations()
        silhouette.path = nil
        host?.removeFromSuperview(); host = nil
        departing?.removeFromSuperview(); departing = nil
        mode = nil; targetSize = .zero
    }

    /// Offscreen diagnostics of this canvas only. Composite native content at the currently presented
    /// mask/opacity; never read the desktop, other windows, or screen-capture APIs.
    func renderPresentation(to url: URL) throws {
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let outline = visiblePath else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(NSColor(srgbRed: 0.22, green: 0.29, blue: 0.37, alpha: 1).cgColor)
        context.fill(bounds)
        context.addPath(outline)
        context.clip()
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)
        for view in [departing, host].compactMap({ $0 }) {
            let opacity = view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? 0
            guard opacity > 0.001, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            // cacheDisplay uses model-layer opacity. Capture opaque content and apply the sampled
            // presentation opacity exactly once, including the departing host whose model is zero.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let modelOpacity = view.layer?.opacity ?? 1
            view.layer?.opacity = 1
            view.cacheDisplay(in: view.bounds, to: bitmap)
            view.layer?.opacity = modelOpacity
            CATransaction.commit()
            guard let image = bitmap.cgImage else { continue }
            context.saveGState()
            context.setAlpha(CGFloat(opacity))
            let offset = view.layer?.presentation()?.transform.m42 ?? 0
            context.translateBy(x: view.frame.minX, y: view.frame.maxY + offset)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: view.bounds.size))
            context.restoreGState()
        }
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}
