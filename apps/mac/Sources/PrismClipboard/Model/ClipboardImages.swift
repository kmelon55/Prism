import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image validation, TIFF normalization and thumbnails with ImageIO.
enum ClipboardImages {
    static func inputLimit(mimeType: String) -> Int {
        mimeType == "image/tiff" ? ClipboardLimits.maxTIFFInputBytes : ClipboardLimits.maxImageBytes
    }

    private static func type(for mimeType: String) -> UTType? {
        switch mimeType {
        case "image/png": .png
        case "image/jpeg": .jpeg
        case "image/webp": .webP
        case "image/tiff": .tiff
        default: nil
        }
    }

    /// Validates captured image bytes. Dimensions are read from the header before anything is decoded, and
    /// TIFF is decoded once and stored as PNG.
    static func payload(bytes: Data, mimeType: String) throws(ClipboardError) -> ClipboardPayload {
        guard !bytes.isEmpty, bytes.count <= inputLimit(mimeType: mimeType) else {
            throw ClipboardError("Image exceeds the clipboard size limit.")
        }
        guard let type = type(for: mimeType) else { throw ClipboardError("Unsupported clipboard image format.") }
        let options = [kCGImageSourceTypeIdentifierHint: type.identifier as CFString, kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let sourceType = CGImageSourceGetType(source) as String?, UTType(sourceType)?.conforms(to: type) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ClipboardError("Clipboard image is invalid or unsupported.") }
        guard ClipboardPolicy.validDimensions(width: width, height: height) else {
            throw ClipboardError("Image exceeds 8,192 pixels per side or 16 megapixels. Copy a smaller image.")
        }
        guard type == .tiff else { return .image(bytes, mimeType: mimeType, width: width, height: height) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ClipboardError("Clipboard image is invalid or exceeds decoder limits.")
        }
        guard let png = encodePNG(image) else { throw ClipboardError("Clipboard image is invalid or unsupported.") }
        guard png.count <= ClipboardLimits.maxImageBytes else {
            throw ClipboardError("Image exceeds 8 MB. Copy a smaller image to save it in history.")
        }
        return .image(png, mimeType: "image/png", width: width, height: height)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A downscaled copy no larger than `maxPixelSize` on its longest side. Originals are never modified.
    static func thumbnail(bytes: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

extension ClipboardStore {
    /// A bounded thumbnail for an image entry, for the selected preview and list rows.
    func thumbnail(id: Int64, maxPixelSize: Int) throws(ClipboardError) -> CGImage {
        guard case .image(let bytes, _, let width, let height) = try payload(id: id) else {
            throw ClipboardError("Only image entries have an image preview.")
        }
        guard bytes.count <= ClipboardLimits.maxImageBytes, ClipboardPolicy.validDimensions(width: width, height: height) else {
            throw ClipboardError("Stored image exceeds supported limits.")
        }
        guard let image = ClipboardImages.thumbnail(bytes: bytes, maxPixelSize: maxPixelSize) else {
            throw ClipboardError("Image preview could not be prepared.")
        }
        return image
    }
}
