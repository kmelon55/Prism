import Foundation

/// `window-management-v1.json`, shared with the Tauri app: `{"cycle","reverseCycle","gap","edgeGap","almostMaximize"}`.
struct WindowOptions: Codable, Equatable, Sendable {
    var cycle = true
    var reverseCycle = false
    var gap = 0
    var edgeGap = 0
    var almostMaximize = 90

    static let gapRange = 0...64
    static let almostMaximizeRange = 50...100

    var isValid: Bool {
        Self.gapRange.contains(gap) && Self.gapRange.contains(edgeGap) && Self.almostMaximizeRange.contains(almostMaximize)
    }
}

enum WindowOptionsError: Error, Equatable {
    case unreadable
    case invalid
    case invalidSaved
    case saveFailed

    var message: String {
        switch self {
        case .unreadable: SystemStrings.localized("Could not read window management options.")
        case .invalid: SystemStrings.localized("Invalid window management options.")
        case .invalidSaved: SystemStrings.localized("Invalid saved window management options.")
        case .saveFailed: SystemStrings.localized("Could not save window options.")
        }
    }
}

/// Reads and writes the options file with the Tauri rules: a missing file means defaults, a malformed file is
/// reported and never silently replaced, and values are range-checked.
struct WindowOptionsStore: Sendable {
    static let fileName = "window-management-v1.json"
    private static let maximumSize = 4096

    let url: URL

    func load() throws(WindowOptionsError) -> WindowOptions {
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumSize else { throw WindowOptionsError.unreadable }
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return WindowOptions()
        } catch let error as WindowOptionsError {
            throw error
        } catch {
            throw .unreadable
        }
        guard let value = try? JSONDecoder().decode(WindowOptions.self, from: data) else { throw .invalidSaved }
        guard value.isValid else { throw .invalid }
        return value
    }

    /// Options for window commands. A damaged file falls back to defaults so layouts keep working;
    /// the settings pane reports the problem.
    func loadOrDefault() -> WindowOptions { (try? load()) ?? WindowOptions() }

    func save(_ options: WindowOptions) throws(WindowOptionsError) {
        guard options.isValid else { throw .invalid }
        _ = try load()
        try write(options)
    }

    /// Replaces a damaged file. Only used after the user explicitly chooses to reset.
    func reset() throws(WindowOptionsError) {
        try write(WindowOptions())
    }

    private func write(_ options: WindowOptions) throws(WindowOptionsError) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(options).write(to: url, options: .atomic)
        } catch {
            throw .saveFailed
        }
    }
}
