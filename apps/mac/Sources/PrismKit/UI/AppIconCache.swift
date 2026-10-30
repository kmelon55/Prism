import AppKit

/// Bounded icon cache. Icons are loaded only for rows that are on screen.
@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    public func removeAll() {
        cache.removeAllObjects()
    }

    public func icon(forPath path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
