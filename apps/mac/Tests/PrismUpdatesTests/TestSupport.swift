import AppKit
import CryptoKit
import Foundation
import PrismKit
@testable import PrismUpdates

/// Serves canned responses by URL. Each test uses its own host, so parallel tests never share responses.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var body = Data()
        var fails = false
        /// Holds the response back, to keep an operation in flight.
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: Response] = [:]
    nonisolated(unsafe) private static var requests: [URL] = []

    static func serve(_ url: URL, _ response: Response) {
        lock.withLock { responses[url] = response }
    }

    static func requestCount(host: String) -> Int {
        lock.withLock { requests.filter { $0.host() == host }.count }
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.lock.withLock {
            Self.requests.append(url)
            return Self.responses[url]
        }
        guard let response, !response.fails else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        let finish = { [self] in
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { finish() }
        } else {
            finish()
        }
    }

    override func stopLoading() {}
}

/// Signs like `tauri signer sign`: a prehashed minisign signature, wrapped in base64.
struct TestSigner {
    let privateKey = Curve25519.Signing.PrivateKey()
    let keyID = Data((0..<8).map { _ in UInt8.random(in: 0...255) })

    var publicKey: String {
        let raw = Data("Ed".utf8) + keyID + privateKey.publicKey.rawRepresentation
        return Data("untrusted comment: minisign public key\n\(raw.base64EncodedString())\n".utf8).base64EncodedString()
    }

    func sign(_ data: Data, comment: String = "timestamp:1700000000\tfile:Prism.app.tar.gz") -> String {
        let signature = try! privateKey.signature(for: BLAKE2b512.hash(data))
        let global = try! privateKey.signature(for: signature + Data(comment.utf8))
        let packet = Data("ED".utf8) + keyID + signature
        let text = "untrusted comment: signature from tauri secret key\n\(packet.base64EncodedString())\ntrusted comment: \(comment)\n\(global.base64EncodedString())\n"
        return Data(text.utf8).base64EncodedString()
    }
}

/// Builds tar archives byte by byte, including the hostile entries the extractor must reject.
struct TarBuilder {
    private(set) var data = Data()

    mutating func file(_ path: String, _ contents: Data = Data(), mode: Int = 0o644) {
        entry(path, type: "0", size: contents.count, mode: mode)
        append(contents)
    }

    mutating func directory(_ path: String) {
        entry(path, type: "5", size: 0, mode: 0o755)
    }

    mutating func symlink(_ path: String, to target: String) {
        entry(path, type: "2", size: 0, mode: 0o755, link: target)
    }

    /// A GNU long-name record, as the Rust `tar` crate writes for paths over 100 bytes.
    mutating func longFile(_ path: String, _ contents: Data) {
        let name = Data(path.utf8) + Data([0])
        entry("././@LongLink", type: "L", size: name.count, mode: 0o644)
        append(name)
        file(String(path.prefix(99)), contents)
    }

    mutating func paxFile(_ path: String, _ contents: Data) {
        var record = " path=\(path)\n"
        var length = record.utf8.count
        while "\(length)\(record)".utf8.count != length { length = "\(length)\(record)".utf8.count }
        record = "\(length)\(record)"
        entry("PaxHeader/x", type: "x", size: record.utf8.count, mode: 0o644)
        append(Data(record.utf8))
        file("ignored-name", contents)
    }

    mutating func entry(_ name: String, type: Character, size: Int, mode: Int, link: String = "") {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ offset: Int, _ length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() { header[offset + index] = byte }
        }
        put(name, 0, 100)
        put(String(format: "%07o", mode), 100, 8)
        put("0000000", 108, 8)
        put("0000000", 116, 8)
        put(String(size, radix: 8).leftPadded(11), 124, 12)
        put("00000000000", 136, 12)
        put("        ", 148, 8)
        header[156] = type.asciiValue!
        put(link, 157, 100)
        put("ustar", 257, 6)
        put("00", 263, 2)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum) + "\0 ", 148, 8)
        data.append(contentsOf: header)
    }

    private mutating func append(_ contents: Data) {
        data.append(contents)
        data.append(Data(count: (512 - contents.count % 512) % 512))
    }

    func finished() -> Data { data + Data(count: 1024) }

    func gzipped() -> Data { gzip(finished()) }
}

func gzip(_ data: Data) -> Data {
    var crc = CRC32()
    crc.update(data)
    var output = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
    output += try! (data as NSData).compressed(using: .zlib) as Data
    for value in [crc.value, UInt32(truncatingIfNeeded: data.count)] {
        withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
    }
    return output
}

private extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

/// A temporary directory removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "prism-updates-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func infoPlist(identifier: String = "dev.prism.desktop", version: String) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": identifier,
        "CFBundleShortVersionString": version,
        "CFBundleExecutable": "Prism",
        "CFBundlePackageType": "APPL",
    ], format: .xml, options: 0)
}

/// A fake installed app on disk (never /Applications).
func makeInstalledApp(in directory: URL, version: String = "0.1.0", identifier: String = "dev.prism.desktop") -> URL {
    let app = directory.appending(path: "Prism.app", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
    try! infoPlist(identifier: identifier, version: version).write(to: app.appending(path: "Contents/Info.plist"))
    try! Data("old".utf8).write(to: app.appending(path: "Contents/MacOS/Prism"))
    return app
}

/// An update archive containing a fake Prism.app.
func makeUpdateArchive(version: String, identifier: String = "dev.prism.desktop") -> Data {
    var tar = TarBuilder()
    tar.directory("Prism.app/")
    tar.directory("Prism.app/Contents/")
    tar.file("Prism.app/Contents/Info.plist", infoPlist(identifier: identifier, version: version))
    tar.directory("Prism.app/Contents/MacOS/")
    tar.file("Prism.app/Contents/MacOS/Prism", Data("new \(version)".utf8), mode: 0o755)
    return tar.gzipped()
}

struct FakeVerifier: CodeSigningVerifier {
    var accepts = true

    func verifyCompatible(candidate: URL, installed: URL) throws {
        guard accepts else { throw CodeSigningFailure.identityChanged }
    }
}

@MainActor
final class FakeContext: PrismContext {
    let paths: AppPaths
    var previousApplication: NSRunningApplication?
    private(set) var reloads: [String] = []

    init(directory: URL) {
        paths = AppPaths(dataDirectory: directory)
    }

    func showPalette() {}
    func hidePalette() {}
    func showPalette(screen: PaletteScreen) {}
    func openSettings(paneID: String?) {}
    func showHUD(_ message: String) {}
    func reloadResults(providerID: String) { reloads.append(providerID) }
}
