import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bounded JPEG attachments: at most 1600 pixels per side and a 1.4 MB data URL, four per conversation.
enum ChatImageCodec {
    static let maxDataURL = 1_400_000
    static let maxSessionImages = 4
    static let prefix = "data:image/jpeg;base64,"
    static let maxFileBytes = 40 * 1024 * 1024

    static func validate(_ image: ChatImage) throws {
        guard image.dataUrl.hasPrefix(prefix) else { throw AIError(L("This is not a valid image attachment.")) }
        if image.dataUrl.utf8.count > maxDataURL { throw AIError(L("The image is too large.")) }
        guard let data = Data(base64Encoded: String(image.dataUrl.dropFirst(prefix.count))),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceTypeIdentifierHint: UTType.jpeg.identifier] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw AIError(L("Could not read the image.")) }
        if width == 0 || height == 0 || width > 1600 || height > 1600 { throw AIError(L("The image dimensions are invalid.")) }
    }

    static func decodedSize(_ image: ChatImage) -> CGSize? {
        guard let data = Data(base64Encoded: String(image.dataUrl.dropFirst(prefix.count))),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Reads only an explicitly chosen or dropped PNG, JPEG or WebP file and re-encodes it as a bounded JPEG.
    static func encode(fileAt url: URL, allowedTypes: Set<UTType>? = [.png, .jpeg, .webP]) throws -> ChatImage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let allowedTypes {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
            guard let type, allowedTypes.contains(where: { type.conforms(to: $0) }) else { throw AIError(L("Choose a PNG, JPEG, or WebP image.")) }
        }
        guard size > 0, size <= maxFileBytes else { throw AIError(L("Choose an image smaller than 40 MB.")) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw AIError(L("Could not read this image.")) }
        return try encode(source)
    }

    static func encode(data: Data) throws -> ChatImage {
        guard data.count <= maxFileBytes, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AIError(L("Could not read this image."))
        }
        return try encode(source)
    }

    private static func encode(_ source: CGImageSource) throws -> ChatImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw AIError(L("Could not read this image.")) }
        if width > 20_000 || height > 20_000 || width * height > 64_000_000 {
            throw AIError(L("This image is too large. Choose a smaller image."))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(1600, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AIError(L("Could not read this image."))
        }
        // JPEG has no alpha channel: flatten transparent screenshots onto white.
        let outWidth = min(thumbnail.width, 1600), outHeight = min(thumbnail.height, 1600)
        guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AIError(L("Could not read this image.")) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        guard let flattened = context.makeImage() else { throw AIError(L("Could not read this image.")) }
        for quality in [0.85, 0.7, 0.55, 0.4] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { break }
            let image = ChatImage(dataUrl: prefix + (output as Data).base64EncodedString())
            if image.dataUrl.utf8.count <= maxDataURL {
                try validate(image)
                return image
            }
        }
        throw AIError(L("This image is too large. Choose a smaller image."))
    }
}
