import AppKit
import Foundation
@testable import PrismDictation

/// Serves canned HTTP responses per host, so suites can run in parallel without sharing state. No network.
final class MockHTTP: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func serve(_ host: String, _ response: Response) {
        lock.lock(); defer { lock.unlock() }
        responses[host] = response
        requests[host] = []
    }

    static func requests(for host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests[host] ?? []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream { recorded.httpBody = Self.read(stream) }
        Self.lock.lock()
        let response = Self.responses[host] ?? Response(status: 404)
        Self.requests[host, default: []].append(recorded)
        Self.lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

/// A recorder that never touches the microphone.
@MainActor
final class FakeRecorder: DictationRecording {
    var onLevel: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts = 0
    var delay: Duration = .zero
    var denied = false
    var running = false
    var outputURL: URL?

    func start() async throws {
        starts += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        if denied { throw DictationError("microphone denied fixture") }
        running = true
    }

    func stop() -> URL? {
        guard running else { return nil }
        running = false
        return outputURL
    }
}

/// A private temporary folder removed when the value is released.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "prism-dictation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: Data = Data([82, 73, 70, 70, 0, 0, 0, 0, 87, 65, 86, 69])) throws -> URL {
        let file = url.appending(path: name)
        try contents.write(to: file)
        return file
    }

    /// An executable shell script, used as a stand-in for whisper-cli.
    func script(_ name: String, _ body: String) throws -> URL {
        let file = url.appending(path: name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Writes the transcript to `-of <path>.txt`, like whisper-cli.
    func whisperFixture(_ text: String = "local fixture transcript") throws -> URL {
        try script("whisper-\(UUID().uuidString)", "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = \"-of\" ]; then shift; printf '\(text)' > \"$1.txt\"; fi; shift; done\n")
    }
}

/// Polls until `condition` holds or about eight seconds pass.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
}

func localSettings(whisperPath: String = "/fixture", modelPath: String = "/fixture.bin") -> DictationSettings {
    var settings = DictationSettings()
    settings.provider = .local
    settings.whisperPath = whisperPath
    settings.modelPath = modelPath
    settings.uiLanguage = "en"
    return settings
}
