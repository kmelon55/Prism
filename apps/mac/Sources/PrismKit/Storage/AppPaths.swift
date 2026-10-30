import Foundation

/// Where Prism keeps its data.
///
/// The released app keeps the Tauri app's bundle identifier and folder so existing clipboard history, library,
/// conversations and settings carry over. Development builds use a separate folder so they never write to the
/// data of the installed app. `PRISM_DATA_DIR` overrides both, which tests and snapshots use.
public struct AppPaths: Sendable {
    public static let releaseBundleIdentifier = "dev.prism.desktop"

    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public static func current(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppPaths {
        if let override = environment["PRISM_DATA_DIR"], !override.isEmpty {
            return AppPaths(dataDirectory: URL(filePath: override, directoryHint: .isDirectory))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = bundleIdentifier == releaseBundleIdentifier ? releaseBundleIdentifier : "dev.prism.native-dev"
        return AppPaths(dataDirectory: support.appending(path: folder, directoryHint: .isDirectory))
    }

    /// The keychain service for `suffix` (for example "ai"). The release app shares the Tauri services so saved
    /// keys carry over; development builds use their own so they never read or change the installed app's keys.
    public static func keychainService(_ suffix: String, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        (bundleIdentifier == releaseBundleIdentifier ? releaseBundleIdentifier : "dev.prism.native-dev") + "." + suffix
    }

    /// A file inside the data directory. Creates the directory on first use.
    public func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        return dataDirectory.appending(path: name)
    }
}
