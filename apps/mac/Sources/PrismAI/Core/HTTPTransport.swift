import Foundation

/// A response whose body arrives in chunks as the network delivers them.
struct HTTPStreamResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: AsyncThrowingStream<Data, any Error>

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Reads the whole body, failing once it exceeds `limit` bytes.
    func collect(limit: Int, tooLarge: AIError, failure: AIError) async throws -> Data {
        var data = Data()
        do {
            for try await chunk in body {
                if data.count + chunk.count > limit { throw tooLarge }
                data.append(chunk)
            }
        } catch let error as AIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure
        }
        return data
    }
}

protocol HTTPTransport: Sendable {
    /// Starts a request and returns once headers arrive. Cancelling the calling task cancels the request.
    func send(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// URLSession with redirects disabled, no cookies or cache, and chunked body delivery.
struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let delegate = StreamingDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(continuation: continuation, task: task, session: session)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPStreamResponse, any Error>?
    private var stream: AsyncThrowingStream<Data, any Error>.Continuation?
    private weak var task: URLSessionTask?
    private var session: URLSession?

    func begin(continuation: CheckedContinuation<HTTPStreamResponse, any Error>, task: URLSessionTask, session: URLSession) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
        self.task = task
        self.session = session
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.onTermination = { [weak dataTask] termination in
            if case .cancelled = termination { dataTask?.cancel() }
        }
        lock.lock()
        stream = continuation
        let pending = self.continuation
        self.continuation = nil
        lock.unlock()
        pending?.resume(returning: HTTPStreamResponse(status: http?.statusCode ?? 0, headers: headers, body: body))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let stream = stream; lock.unlock()
        stream?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let pending = continuation, stream = stream
        continuation = nil
        self.stream = nil
        self.session = nil
        lock.unlock()
        if let pending {
            // A redirect that was refused completes with the 3xx response and no headers callback.
            if let response = task.response as? HTTPURLResponse, error == nil {
                let (body, finished) = AsyncThrowingStream<Data, any Error>.makeStream()
                finished.finish()
                pending.resume(returning: HTTPStreamResponse(status: response.statusCode, headers: [:], body: body))
            } else {
                pending.resume(throwing: error ?? URLError(.badServerResponse))
            }
        }
        if let error { stream?.finish(throwing: error) } else { stream?.finish() }
        session.finishTasksAndInvalidate()
    }
}

/// Runs `body` with a deadline. The body is cancelled when the deadline passes.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, error: AIError, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw error
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw error }
        return result
    }
}
