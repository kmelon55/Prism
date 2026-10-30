import Foundation

public struct InstalledApplication: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Localized name shown in Finder, for example "계산기" for Calculator on a Korean system.
    public let name: String
    /// Bundle file name without `.app`. Usually English, so it stays searchable on localized systems.
    public let fileName: String
    public let bundleIdentifier: String?

    public init(path: String, name: String, fileName: String, bundleIdentifier: String?) {
        self.path = path
        self.name = name
        self.fileName = fileName
        self.bundleIdentifier = bundleIdentifier
    }

    public var searchCandidate: SearchCandidate {
        var aliases = ApplicationAliases.common(for: name) + ApplicationAliases.common(for: fileName)
        if fileName != name { aliases.append(fileName) }
        return SearchCandidate(id: "app:\(path)", title: name, section: "Applications", searchAliases: aliases)
    }
}

public enum ApplicationCatalog {
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(filePath: "/Applications"),
            URL(filePath: "/System/Applications"),
            // Safari in /Applications can link into the system Cryptex app volume.
            URL(filePath: "/System/Cryptexes/App/System/Applications"),
            // Finder lives outside the application directories. Include only its bundle.
            URL(filePath: "/System/Library/CoreServices/Finder.app"),
            home.appending(path: "Applications"),
        ]
    }

    /// Finds launchable app bundles, sorted by display name. Duplicate bundle identifiers keep the first root.
    public static func scan(roots: [URL] = defaultRoots(), fileManager: FileManager = .default) -> [InstalledApplication] {
        var seenPaths = Set<String>()
        var seenBundles = Set<String>()
        var applications: [InstalledApplication] = []

        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().path
            guard seenPaths.insert(resolved).inserted else { return }
            let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any]
            if info?["LSBackgroundOnly"] as? Bool == true { return }
            let bundleIdentifier = info?["CFBundleIdentifier"] as? String
            if let bundleIdentifier, !seenBundles.insert(bundleIdentifier).inserted { return }
            let fileName = url.deletingPathExtension().lastPathComponent
            let displayName = fileManager.displayName(atPath: url.path)
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            applications.append(InstalledApplication(path: url.path, name: name, fileName: fileName, bundleIdentifier: bundleIdentifier))
        }

        func visit(_ directory: URL, depth: Int) {
            guard depth <= 2, let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if child.pathExtension == "app" {
                    add(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(child, depth: depth + 1)
                }
            }
        }

        for root in roots {
            if root.pathExtension == "app" {
                if fileManager.fileExists(atPath: root.path) { add(root) }
            } else {
                visit(root, depth: 0)
            }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
