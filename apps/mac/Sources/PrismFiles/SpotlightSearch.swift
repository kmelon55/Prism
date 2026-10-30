import CoreServices
import Foundation

/// Filename search through the Spotlight index under the home folder. Runs a synchronous `MDQuery` on a
/// background queue, stops it when the Swift task is cancelled or after `timeout`, and bounds the number of
/// results it reads. Equivalent to the Tauri `mdfind -onlyin ~ -name` call, without a subprocess.
enum SpotlightSearch {
    static let maxResults = 1_500

    /// `kMDItemFSName` substring clauses for every token, each in its NFC and NFD forms so decomposed Korean
    /// filenames match composed queries and the reverse.
    static func queryString(for query: FilenameQuery) -> String? {
        let tokens = query.tokenTexts
        guard !tokens.isEmpty else { return nil }
        let clauses = tokens.map { token -> String in
            // Swift compares strings by canonical equivalence, so compare the scalars to keep both forms.
            let composed = token.precomposedStringWithCanonicalMapping
            let decomposed = token.decomposedStringWithCanonicalMapping
            let forms = composed.unicodeScalars.elementsEqual(decomposed.unicodeScalars) ? [composed] : [composed, decomposed]
            let parts = forms.map { "kMDItemFSName == \"*\(escape($0))*\"cd" }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " || ") + ")"
        }
        return clauses.joined(separator: " && ")
    }

    static func escape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "\\\"*?'".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    static func search(
        _ query: FilenameQuery, scope: String = NSHomeDirectory(), timeout: Duration = .milliseconds(1_500)
    ) async -> [FileHit] {
        guard let string = queryString(for: query) else { return [] }
        return await run(string, scope: scope, timeout: timeout)
    }

    /// Files used in the last two weeks, most recent first, for the Files screen before anything is typed.
    static func recent(scope: String = NSHomeDirectory(), limit: Int = 60) async -> [FileHit] {
        let hits = await run("kMDItemLastUsedDate >= $time.today(-14) && kMDItemContentType != \"public.folder\"", scope: scope, timeout: .seconds(1))
        return Array(hits.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }.prefix(limit))
    }

    private static func run(_ string: String, scope: String, timeout: Duration) async -> [FileHit] {
        let run = SpotlightRun(query: string, scope: scope)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: run.execute(timeout: timeout))
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// Drops results outside `scope`, inside hidden, excluded or app-bundle folders, and symbolic links.
    static func accept(path: String, scope: String) -> FileHit? {
        let prefix = scope.hasSuffix("/") ? scope : scope + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let components = path.dropFirst(prefix.count).split(separator: "/")
        guard !components.isEmpty, !components.contains(where: { FileSearchKey.isExcluded(String($0)) || $0.hasSuffix(".app") }) else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let mode = info.st_mode & S_IFMT
        guard mode == S_IFDIR || mode == S_IFREG else { return nil }
        return FileHit(path: path, isDirectory: mode == S_IFDIR)
    }
}

/// One cancellable Spotlight query. `cancel` may be called from any thread.
private final class SpotlightRun: @unchecked Sendable {
    private let lock = NSLock()
    private let queryString: String
    private let scope: String
    private var query: MDQuery?
    private var cancelled = false

    init(query: String, scope: String) {
        queryString = query
        self.scope = scope
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let query { MDQueryStop(query) }
    }

    func execute(timeout: Duration) -> [FileHit] {
        let attributes = [kMDItemPath, kMDItemLastUsedDate] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, attributes, nil) else { return [] }
        MDQuerySetSearchScope(query, [scope] as CFArray, 0)
        MDQuerySetMaxCount(query, SpotlightSearch.maxResults)
        lock.lock()
        if cancelled { lock.unlock(); return [] }
        self.query = query
        lock.unlock()

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.cancel() }
        MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))

        // A timed-out query still returns what it gathered; a superseded one is discarded by the caller.
        lock.lock()
        self.query = nil
        lock.unlock()

        var hits: [FileHit] = []
        let count = min(MDQueryGetResultCount(query), SpotlightSearch.maxResults)
        hits.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemPath, index) else { continue }
            let path = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            guard var hit = SpotlightSearch.accept(path: path, scope: scope) else { continue }
            if let used = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemLastUsedDate, index) {
                hit.lastUsed = Unmanaged<CFDate>.fromOpaque(used).takeUnretainedValue() as Date
            }
            hits.append(hit)
        }
        return hits
    }
}
