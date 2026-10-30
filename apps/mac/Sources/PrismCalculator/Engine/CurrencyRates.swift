import Foundation

/// One ECB reference table with EUR as the base, stored as `currency-ecb-v1.json` in the same shape as the
/// Tauri app (`date`, `fetchedAt`, `rates`, `stale`).
struct RateSnapshot: Codable, Equatable, Sendable {
    var date: String
    var fetchedAt: UInt64
    var rates: [String: Double]
    var stale: Bool
}

/// The shared, serialized rate cache from `currency.rs`: one fixed HTTPS request, a one-hour fresh window,
/// a seven-day stale fallback after a failed refresh, and a 15-second retry backoff.
actor CurrencyRates {
    static let endpoint = URL(string: "https://api.frankfurter.dev/v2/rates?base=EUR&providers=ECB")!
    static let fileName = "currency-ecb-v1.json"
    static let maxBytes = 64 * 1024
    static let hour: UInt64 = 60 * 60
    static let maxAge: UInt64 = 7 * 24 * hour

    typealias Fetch = @Sendable () async throws -> Data
    typealias Clock = @Sendable () -> UInt64

    private let file: URL?
    private let fetch: Fetch
    private let now: Clock
    private var snapshot: RateSnapshot?
    private var diskLoaded = false
    private var retryAfter: UInt64 = 0
    private var refresh: Task<RateSnapshot?, Never>?

    init(file: URL?, fetch: @escaping Fetch = CurrencyRates.download, now: @escaping Clock = CurrencyRates.systemNow) {
        self.file = file
        self.fetch = fetch
        self.now = now
    }

    /// For tests: start from a known in-memory state.
    init(snapshot: RateSnapshot?, retryAfter: UInt64, fetch: @escaping Fetch, now: @escaping Clock) {
        self.file = nil
        self.fetch = fetch
        self.now = now
        self.snapshot = snapshot
        self.diskLoaded = true
        self.retryAfter = retryAfter
    }

    /// The current table, refreshing it when it is older than an hour. A refresh that fails falls back to
    /// a table no older than seven days marked `stale`, and otherwise throws.
    func load() async throws(AnswerError) -> RateSnapshot {
        loadDiskIfNeeded()
        if let snapshot, Self.isValid(snapshot, now: now()), now() - snapshot.fetchedAt < Self.hour {
            return snapshot
        }
        if now() >= retryAfter {
            // The request runs in its own task so a newer keystroke that cancels this search does not
            // cancel the shared refresh, and concurrent searches wait for the same request.
            let task = refresh ?? Task { [fetch, now] in
                guard let data = try? await fetch() else { return nil }
                return try? Self.parse(data, now: now())
            }
            refresh = task
            let fetched = await task.value
            if refresh == task { refresh = nil }
            if let fetched {
                snapshot = fetched
                retryAfter = 0
                save(fetched)
                return fetched
            }
            retryAfter = now() + 15
        }
        guard var cached = snapshot, Self.isValid(cached, now: now()) else { throw Self.unavailable }
        cached.stale = true
        return cached
    }

    static var unavailable: AnswerError {
        AnswerError(localized("Exchange rates are unavailable. Check your connection and try again."))
    }

    private func loadDiskIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let file,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxBytes,
              let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(RateSnapshot.self, from: data),
              Self.isValid(stored, now: now())
        else { return }
        snapshot = stored
    }

    private func save(_ snapshot: RateSnapshot) {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Validation

    private struct Row: Decodable {
        let date: String
        let base: String
        let quote: String
        let rate: Double
    }

    static func parse(_ data: Data, now: UInt64) throws(AnswerError) -> RateSnapshot {
        guard data.count <= maxBytes,
              let rows = try? JSONDecoder().decode([Row].self, from: data),
              let first = rows.first, rows.count <= 64
        else { throw unavailable }
        var snapshot = RateSnapshot(date: first.date, fetchedAt: now, rates: [:], stale: false)
        for row in rows {
            guard row.base == "EUR", row.date == snapshot.date, snapshot.rates[row.quote] == nil else { throw unavailable }
            snapshot.rates[row.quote] = row.rate
        }
        // Some provider responses omit the base currency's identity record.
        if snapshot.rates["EUR"] == nil { snapshot.rates["EUR"] = 1 }
        guard isValid(snapshot, now: now) else { throw unavailable }
        return snapshot
    }

    static func isValid(_ snapshot: RateSnapshot, now: UInt64) -> Bool {
        guard let rateTime = midnightUTC(snapshot.date), rateTime >= 0 else { return false }
        let rateSeconds = UInt64(rateTime)
        return rateSeconds <= now && now - rateSeconds <= maxAge
            && snapshot.fetchedAt <= now && now - snapshot.fetchedAt <= maxAge
            && (2...64).contains(snapshot.rates.count)
            && snapshot.rates["EUR"] == 1
            && snapshot.rates.allSatisfy { code, rate in
                code.utf8.count == 3 && code.utf8.allSatisfy { (65...90).contains($0) }
                    && rate.isFinite && rate > 0 && rate <= 1_000_000_000
            }
    }

    private static let datePattern = Pattern(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})$"#)

    /// Seconds since 1970 for `YYYY-MM-DD` at 00:00 UTC, or nil for an impossible calendar date.
    static func midnightUTC(_ text: String) -> Int64? {
        guard let match = datePattern.match(text),
              let year = match[1].flatMap({ Int($0) }), let month = match[2].flatMap({ Int($0) }),
              let day = match[3].flatMap({ Int($0) }),
              let days = CivilDate(year: year, month: month, day: day)?.daysSinceEpoch
        else { return nil }
        return days * 86_400
    }

    // MARK: Network

    @Sendable static func systemNow() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970))
    }

    /// HTTPS only, no redirects, a four-second timeout and a 64 KiB body limit.
    @Sendable static func download() async throws -> Data {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https", http.expectedContentLength <= Int64(maxBytes)
        else { throw URLError(.badServerResponse) }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return body
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirects()

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
