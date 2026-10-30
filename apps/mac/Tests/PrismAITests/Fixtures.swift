import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PrismAI

enum Fixture {
    /// A small valid JPEG attachment, like the Rust `ai_capture::tests::fixture`.
    static func image(width: Int = 2, height: Int = 2) -> ChatImage {
        ChatImage(dataUrl: ChatImageCodec.prefix + jpeg(width: width, height: height).base64EncodedString())
    }

    static func jpeg(width: Int, height: Int) -> Data { encode(width: width, height: height, type: .jpeg) }

    static func encode(width: Int, height: Int, type: UTType) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func temporaryDirectory(_ name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "prism-ai-tests-\(name.filter(\.isLetter))-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func message(_ role: String, _ content: String) -> AIMessage { AIMessage(role: role, content: content) }
}
