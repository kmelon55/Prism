import AppKit
import CoreImage
import SwiftUI

/// Render system artwork once at the view's backing-pixel size.
public struct PrismFileIcon: NSViewRepresentable {
    public let path: String

    public init(path: String) { self.path = path }

    public func makeNSView(context: Context) -> NSImageView {
        let view = FileIconImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        return view
    }

    public func updateNSView(_ view: NSImageView, context: Context) {
        (view as? FileIconImageView)?.setPath(path)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        // NSImageView's 32pt intrinsic size otherwise overflows a smaller SwiftUI frame.
        CGSize(width: proposal.width ?? 32, height: proposal.height ?? 32)
    }
}

@MainActor
final class FileIconImageView: NSImageView {
    private var path: String?
    private var loading: (key: String, task: Task<Void, Never>)?

    func setPath(_ path: String) {
        // A recycled row must not keep showing the previous file's icon while the new one loads.
        if path != self.path { image = nil }
        self.path = path
        refreshImage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshImage()
    }

    /// Cached artwork appears immediately. Anything else loads off the main thread: after a long idle, Icon Services
    /// takes tens of milliseconds per icon, which used to stall the palette's first frame.
    private func refreshImage() {
        guard let path, bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size
        let pixels = convertToBacking(bounds).size
        let key = AppIconCache.key(path: path, size: size, pixels: pixels)
        if let cached = AppIconCache.shared.cachedRaster(key) {
            loading?.task.cancel()
            loading = nil
            if image !== cached { image = cached }
            return
        }
        guard loading?.key != key else { return }
        loading?.task.cancel()
        loading = (key, Task { [weak self] in
            let next = await AppIconCache.shared.rasterizedIcon(forPath: path, size: size, pixels: pixels)
            guard let self, !Task.isCancelled, self.path == path else { return }
            self.image = next
            self.loading = nil
        })
    }
}

/// Bounded icon cache. Icons are loaded only for rows that are on screen.
@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
    private let rasterCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    public func removeAll() {
        cache.removeAllObjects()
        rasterCache.removeAllObjects()
    }

    public func icon(forPath path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }

    static func key(path: String, size: CGSize, pixels: CGSize) -> String {
        "\(path)|\(size.width)x\(size.height)|\(Int(pixels.width.rounded()))x\(Int(pixels.height.rounded()))"
    }

    func cachedRaster(_ key: String) -> NSImage? { rasterCache.object(forKey: key as NSString) }

    private var inflight: [String: Task<CGImage?, Never>] = [:]

    /// Loads and downsamples system artwork in the background; concurrent requests for one key share the work.
    func rasterizedIcon(forPath path: String, size: CGSize, pixels: CGSize) async -> NSImage {
        let key = Self.key(path: path, size: size, pixels: pixels)
        if let cached = cachedRaster(key) { return cached }
        let width = max(1, Int(pixels.width.rounded()))
        let height = max(1, Int(pixels.height.rounded()))
        let task = inflight[key] ?? Task.detached(priority: .userInitiated) {
            Self.render(path: path, width: width, height: height)
        }
        inflight[key] = task
        let output = await task.value
        inflight[key] = nil
        if let cached = cachedRaster(key) { return cached }
        guard let output else { return icon(forPath: path) }
        let representation = NSBitmapImageRep(cgImage: output)
        representation.size = size
        let result = NSImage(size: size)
        result.addRepresentation(representation)
        rasterCache.setObject(result, forKey: key as NSString, cost: width * height * 4)
        return result
    }

    private nonisolated(unsafe) static let rasterContext = CIContext(options: [.cacheIntermediates: false])

    /// Icon Services and Core Image are safe off the main thread; the result is a plain bitmap.
    private nonisolated static func render(path: String, width: Int, height: Int) -> CGImage? {
        let original = NSWorkspace.shared.icon(forFile: path)
        // Icon Services' small representations can already be softened. Start from ample artwork,
        // preserving system badges/appearance, instead of resizing a 24/32px rendition again.
        let sourceSize = CGFloat(max(128, max(width, height) * 4))
        var rect = CGRect(x: 0, y: 0, width: sourceSize, height: sourceSize)
        guard let source = original.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: source)
        let scaled = input.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: CGFloat(height) / CGFloat(source.height),
            kCIInputAspectRatioKey: (CGFloat(width) / CGFloat(source.width)) / (CGFloat(height) / CGFloat(source.height))
        ])
        return rasterContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
