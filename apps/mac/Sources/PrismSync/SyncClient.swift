import PrismKit
import Foundation

protocol SyncTransport: Sendable {
  func request<T: Decodable & Sendable>(_ path: String, server: String, token: String, method: String,
    body: [String: String]?, raw: Data?) async throws -> T
}
extension SyncTransport {
  func request<T: Decodable & Sendable>(_ path: String, server: String, token: String, method: String = "GET",
    body: [String: String]? = nil, raw: Data? = nil) async throws -> T {
    try await request(path,server:server,token:token,method:method,body:body,raw:raw)
  }
}
actor SyncClient: SyncTransport {
  private var clipCache: (scope: String, etag: String, data: Data)?
  private let session: URLSession
  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    config.httpMaximumConnectionsPerHost = 2
    config.urlCache = nil
    config.httpShouldSetCookies = false
    session = URLSession(configuration: config, delegate: SyncRedirectPolicy(), delegateQueue: nil)
  }
  static func validatedServer(_ value: String) throws -> String {
    guard let url = URL(string: value), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/"
    else { throw SyncFailure.message(String(localized: "Enter an HTTPS server URL without a path or credentials.", bundle: .module.prismLocalized)) }
    return value.hasSuffix("/") ? String(value.dropLast()) : value
  }
  func request<T: Decodable & Sendable>(
    _ path: String, server: String, token: String, method: String = "GET",
    body: [String: String]? = nil, raw: Data? = nil
  ) async throws -> T {
    let base = try Self.validatedServer(server)
    var request = URLRequest(url: URL(string: base + "/api/v1/" + path)!)
    request.httpMethod = method
    let scope = base + token
    if path == "clips", method == "GET", let cache = clipCache, cache.scope == scope {
      request.setValue(cache.etag, forHTTPHeaderField: "If-None-Match")
    }
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if body != nil || raw != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try raw ?? JSONEncoder().encode(body!)
    }
    let (bytes, response) = try await session.bytes(for: request)
    if (response as? HTTPURLResponse)?.statusCode == 304, let cache = clipCache,
      cache.scope == scope
    {
      return try JSONDecoder().decode(T.self, from: cache.data)
    }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw SyncFailure.message(
        code == 409
          ? String(localized: "Changes conflict with another device. Refresh, then import the shared settings or keep this device's settings.", bundle: .module.prismLocalized) : String(localized: "Server request failed (\(code)).", bundle: .module.prismLocalized))
    }
    // A server cannot force an unbounded allocation on the client.
    var data = Data()
    for try await byte in bytes {
      guard data.count < 5_000_000 else { throw SyncFailure.message(String(localized: "The server response is too large.", bundle: .module.prismLocalized)) }
      data.append(byte)
    }
    if path == "clips", method == "GET", let etag = http.value(forHTTPHeaderField: "ETag") {
      clipCache = (scope, etag, data)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}

// A server migration must be explicit; never forward a pairing code or device token to a redirect.
private final class SyncRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
