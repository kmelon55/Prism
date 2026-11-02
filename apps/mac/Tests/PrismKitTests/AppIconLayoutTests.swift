import AppKit
import SwiftUI
import Testing
@testable import PrismKit

@MainActor
struct AppIconLayoutTests {
    @Test func rasterCacheSeparatesDisplayScalesAndClearsBothDensities() async throws {
        let cache = AppIconCache()
        let path = "/System/Library/CoreServices/Finder.app"
        let size = CGSize(width: 24, height: 24)
        let standard = await cache.rasterizedIcon(forPath: path, size: size, pixels: size)
        let retina = await cache.rasterizedIcon(forPath: path, size: size, pixels: CGSize(width: 48, height: 48))
        let standardRep = try #require(standard.representations.first)
        let retinaRep = try #require(retina.representations.first)
        #expect(standardRep.pixelsWide == 24 && standardRep.pixelsHigh == 24)
        #expect(retinaRep.pixelsWide == 48 && retinaRep.pixelsHigh == 48)
        #expect(standard.size == size && retina.size == size)
        let again = await cache.rasterizedIcon(forPath: path, size: size, pixels: size)
        #expect(standard === again)
        #expect(standard !== retina)
        cache.removeAll()
        let reloaded = await cache.rasterizedIcon(forPath: path, size: size, pixels: size)
        #expect(standard !== reloaded)
    }

    @Test(arguments: [16.0, 24.0, 32.0])
    func nativeImageRespectsTheRequestedSize(size: Double) async throws {
        _ = NSApplication.shared
        let slot = size + 2
        let host = NSHostingView(rootView: PrismFileIcon(path: "/System/Library/CoreServices/Finder.app")
            .frame(width: size, height: size)
            .frame(width: slot, height: slot))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: slot, height: slot),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        func imageView(in view: NSView) -> NSImageView? {
            if let image = view as? NSImageView { return image }
            return view.subviews.lazy.compactMap { imageView(in: $0) }.first
        }
        let image = try #require(imageView(in: host))
        #expect(image.bounds.size == CGSize(width: size, height: size))
        let actualFrame = image.convert(image.bounds, to: host)
        #expect(actualFrame == CGRect(x: 1, y: 1, width: size, height: size))
        // Artwork loads off the main thread.
        for _ in 0..<200 where image.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pixels = image.convertToBacking(image.bounds).size
        let representation = try #require(image.image?.representations.first)
        #expect(representation.pixelsWide == Int(pixels.width.rounded()))
        #expect(representation.pixelsHigh == Int(pixels.height.rounded()))
    }
}
