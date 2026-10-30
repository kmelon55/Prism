import AppKit

/// Decodes image thumbnails one at a time on a background queue and keeps a small, cost-bounded cache.
/// Requests for rows that scrolled away are skipped before they decode. Entry IDs are never reused, so
/// they are safe cache keys.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private let queue = DispatchQueue(label: "dev.prism.clipboard.thumbnails", qos: .userInitiated)

    func cached(id: Int64, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: key(id, maxPixelSize))
    }

    func image(id: Int64, maxPixelSize: Int, store: ClipboardStore) async -> NSImage? {
        if let cached = cached(id: id, maxPixelSize: maxPixelSize) { return cached }
        let flag = CancellationFlag()
        let decoded: DecodedImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !flag.isCancelled else { return continuation.resume(returning: nil) }
                    let image = try? store.thumbnail(id: id, maxPixelSize: maxPixelSize)
                    continuation.resume(returning: image.map(DecodedImage.init))
                }
            }
        } onCancel: {
            flag.cancel()
        }
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        cache.setObject(image, forKey: key(id, maxPixelSize), cost: decoded.image.bytesPerRow * decoded.image.height)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private func key(_ id: Int64, _ size: Int) -> NSString { "\(id)-\(size)" as NSString }
}

private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
