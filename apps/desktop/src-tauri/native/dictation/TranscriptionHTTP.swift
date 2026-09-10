import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
enum TranscriptionHTTP {
    // Keep audio and credentials out of caches; do not follow a provider's redirect.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 150
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in stream {
            guard data.count < 1_048_576 else { throw DictationFailure("전사 응답이 너무 큽니다.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
}
