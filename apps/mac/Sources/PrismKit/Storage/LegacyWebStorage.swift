import Foundation

/// The Tauri app's WebView local storage, read-only. Its settings (`prism:preferences`) lived there rather than
/// in the data folder, so the native app imports them from here.
public enum LegacyWebStorage {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/WebKit/\(AppPaths.releaseBundleIdentifier)/WebsiteData")
    }

    /// The saved `prism:preferences` object, or nil when the Tauri storage is missing or unreadable.
    public static func preferences(webKitRoot: URL = defaultRoot) -> [String: Any]? {
        for url in localStorageFiles(webKitRoot) {
            guard let database = try? SQLiteDatabase(url: url, readOnly: true),
                  let rows = try? database.query("SELECT value FROM ItemTable WHERE key = ?", ["prism:preferences"], row: { $0.data("value") }),
                  let blob = rows.first ?? nil,
                  let object = object(fromLocalStorageValue: blob) else { continue }
            return object
        }
        return nil
    }

    /// `WebsiteData/Default/<origin salt>/<origin salt>/LocalStorage/localstorage.sqlite3`.
    public static func localStorageFiles(_ root: URL) -> [URL] {
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
    public static func object(fromLocalStorageValue blob: Data) -> [String: Any]? {
        guard let text = String(data: blob, encoding: .utf16LittleEndian) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}
