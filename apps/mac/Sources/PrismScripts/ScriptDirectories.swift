import CoreServices
import Foundation
import PrismKit

/// The configured script folders, in `script-directories-v1.json`. The Tauri app kept them in its WebView
/// preferences (`prism:preferences` → `scriptDirectories`), which are imported once on first launch.
struct ScriptDirectoriesStore: Sendable {
    struct File: Codable, Equatable {
        var version = 1
        var directories: [String]
    }

    static let fileName = "script-directories-v1.json"

    let store: JSONFileStore<File>
    let legacyImport: @Sendable () -> [String]?

    init(paths: AppPaths, legacyImport: (@Sendable () -> [String]?)? = nil) {
        store = JSONFileStore(url: paths.file(Self.fileName))
        let isRelease = paths.dataDirectory.lastPathComponent == AppPaths.releaseBundleIdentifier
        self.legacyImport = legacyImport ?? { isRelease ? LegacyScriptDirectories.read() : nil }
    }

    /// Reads the saved folders. Without a file, imports the Tauri preferences and saves them natively.
    func load() -> [String] {
        if let file = store.load() { return Self.normalize(file.directories) }
        guard FileManager.default.fileExists(atPath: store.url.path) == false,
              let legacy = legacyImport().map(Self.normalize) else { return [] }
        try? store.save(File(directories: legacy))
        return legacy
    }

    func save(_ directories: [String]) throws {
        try store.save(File(directories: Self.normalize(directories)))
    }

    /// `readScriptDirectories` in App.tsx: trimmed, non-empty, at most 4,096 characters, unique, at most 32.
    static func normalize(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return Array(directories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 4_096 && seen.insert($0).inserted }
            .prefix(ScriptLimits.maxDirectories))
    }
}

/// Reads `scriptDirectories` from the Tauri WebView's local storage, read-only.
enum LegacyScriptDirectories {
    static func read(webKitRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/WebKit/\(AppPaths.releaseBundleIdentifier)/WebsiteData")) -> [String]? {
        for url in localStorageFiles(webKitRoot) {
            guard let database = try? SQLiteDatabase(url: url, readOnly: true),
                  let rows = try? database.query("SELECT value FROM ItemTable WHERE key = ?", ["prism:preferences"], row: { $0.data("value") }),
                  let blob = rows.first ?? nil,
                  let directories = directories(fromLocalStorageValue: blob) else { continue }
            return directories
        }
        return nil
    }

    /// `WebsiteData/Default/<origin salt>/<origin salt>/LocalStorage/localstorage.sqlite3`.
    static func localStorageFiles(_ root: URL) -> [URL] {
        let manager = FileManager.default
        let base = root.appending(path: "Default")
        var files: [URL] = []
        for outer in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for inner in (try? manager.contentsOfDirectory(at: outer, includingPropertiesForKeys: nil)) ?? [] {
                let file = inner.appending(path: "LocalStorage/localstorage.sqlite3")
                if manager.fileExists(atPath: file.path) { files.append(file) }
            }
        }
        return files
    }

    /// WebKit stores local storage values as UTF-16LE.
    static func directories(fromLocalStorageValue blob: Data) -> [String]? {
        guard let text = String(data: blob, encoding: .utf16LittleEndian),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let directories = object["scriptDirectories"] as? [Any] else { return nil }
        return directories.compactMap { $0 as? String }
    }
}

/// Watches the configured folders with FSEvents and reports changes after a short quiet period.
@MainActor
final class ScriptDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var debounce: Task<Void, Never>?
    private let delay: Duration
    private let onChange: @MainActor () -> Void

    init(delay: Duration = .milliseconds(400), onChange: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.onChange = onChange
    }

    isolated deinit { stop() }

    func watch(_ directories: [String]) {
        stop()
        let paths = directories.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated {
                Unmanaged<ScriptDirectoryWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        debounce?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func schedule() {
        debounce?.cancel()
        debounce = Task { [delay, onChange] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
