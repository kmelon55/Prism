import Foundation

extension Notification.Name {
    /// Selection, keys, tools or the custom connection changed. Settings and the chat window both reload.
    static let prismAISettingsChanged = Notification.Name("dev.prism.ai.settings-changed")
    /// The usage ledger recorded or finished a request.
    static let prismAIUsageChanged = Notification.Name("dev.prism.ai.usage-changed")
}

/// Small JSON preference files shared with the Tauri app. Writes go to a temporary file and are renamed into place.
enum AIFileIO {
    static func read(_ url: URL, limit: Int) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError || !FileManager.default.fileExists(atPath: url.path) { return nil }
            throw error
        }
        guard (attributes[.size] as? Int ?? 0) <= limit else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: url)
    }

    /// Like Rust's `canonicalize`: resolves every symlink, including `/var` → `/private/var`.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingPathExtension().appendingPathExtension("tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// `ai-selection-v1.json`: the default provider and model for new conversations.
struct AISelectionStore: Sendable {
    let url: URL
    private static let lock = NSLock()

    func load() throws -> AISelection? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }

    private func read() throws -> AISelection? {
        let data: Data?
        do { data = try AIFileIO.read(url, limit: 4096) } catch { throw AIError(L("Could not read saved AI settings.")) }
        guard let data else { return nil }
        guard let value = try? JSONDecoder().decode(AISelection.self, from: data) else { throw AIError(L("Invalid AI settings format.")) }
        try value.validate()
        return value
    }

    @discardableResult
    func save(_ selection: AISelection) throws -> AISelection {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try selection.validate()
        do {
            try AIFileIO.write(try JSONEncoder().encode(selection), to: url)
        } catch {
            throw AIError(L("Could not save model selection."))
        }
        guard let saved = try read() else { throw AIError(L("Could not verify the saved model selection.")) }
        return saved
    }
}

/// `ai-compatible-v1.json`: one explicitly configured Chat Completions server. Its key is scoped to the exact base URL.
public struct CompatibleConnection: Codable, Equatable, Sendable {
    public var baseUrl: String
    public var hasKey: Bool

    public init(baseUrl: String = "", hasKey: Bool = false) {
        self.baseUrl = baseUrl
        self.hasKey = hasKey
    }

    static func normalize(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = AIError(L("Enter a valid API base URL."))
        guard !raw.isEmpty, raw.utf8.count <= 2048, !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              var components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else { throw invalid }
        guard ["http", "https"].contains(scheme), components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIError(L("Use an HTTP(S) base URL without credentials, query parameters or fragments."))
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") || path.hasSuffix("/models") {
            throw AIError(L("Enter the API base URL, such as http://localhost:11434/v1."))
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.path = path + "/"
        guard let result = components.string else { throw invalid }
        return result
    }
}

struct CompatibleStore: Sendable {
    let url: URL
    private static let lock = NSLock()

    func load() throws -> CompatibleConnection {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }

    private func read() throws -> CompatibleConnection {
        let data: Data?
        do { data = try AIFileIO.read(url, limit: 8192) } catch { throw AIError(L("Could not read the custom API connection.")) }
        guard let data else { return CompatibleConnection() }
        guard let value = try? JSONDecoder().decode(CompatibleConnection.self, from: data) else {
            throw AIError(L("The custom API connection is malformed."))
        }
        _ = try CompatibleConnection.normalize(value.baseUrl)
        return value
    }

    /// Saves the base URL and, when given, a key. A nil key keeps the saved key only for the same base URL.
    func save(baseUrl: String, key: String?, keys: AIKeyStore) throws -> CompatibleConnection {
        let base = try CompatibleConnection.normalize(baseUrl)
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, key.utf8.count > 4096 || !key.isEmpty && !AIRequest.isASCIIGraphic(key) {
            throw AIError(L("Enter an API key without spaces or line breaks."))
        }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let previous = try read()
        let hasKey = key.map { !$0.isEmpty } ?? (previous.baseUrl == base && previous.hasKey)
        do {
            try keys.saveCompatibleKey(key, base: base)
        } catch {
            throw AIError(L("Could not save the custom API key in Keychain."))
        }
        let value = CompatibleConnection(baseUrl: base, hasKey: hasKey)
        do {
            try AIFileIO.write(try JSONEncoder().encode(value), to: url)
        } catch {
            throw AIError(L("Could not save the custom API connection."))
        }
        return value
    }
}

/// A folder the user granted from a native folder chooser.
public struct AIFolderGrant: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
}

/// `ai-tools-v1.json`. Web search is built in; the legacy persisted `webSearch` flag is ignored and never written.
public struct AIToolSettings: Codable, Equatable, Sendable {
    public var webSearch = true
    public var localFiles = false
    public var maxOutputTokens = 16_384
    public var folders: [AIFolderGrant] = []

    public static let outputLimits = [4096, 16_384, 32_768]

    public init(localFiles: Bool = false, maxOutputTokens: Int = 16_384, folders: [AIFolderGrant] = []) {
        self.localFiles = localFiles
        self.maxOutputTokens = maxOutputTokens
        self.folders = folders
    }

    enum CodingKeys: String, CodingKey { case localFiles, maxOutputTokens, folders }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localFiles = try container.decodeIfPresent(Bool.self, forKey: .localFiles) ?? false
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 16_384
        folders = try container.decodeIfPresent([AIFolderGrant].self, forKey: .folders) ?? []
    }
}

struct AIToolStore: Sendable {
    let url: URL
    private static let lock = NSLock()

    func load() throws -> AIToolSettings {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }

    private func read() throws -> AIToolSettings {
        let data: Data?
        do { data = try AIFileIO.read(url, limit: 32_768) } catch { throw AIError(L("Could not read tool settings.")) }
        guard let data else { return AIToolSettings() }
        guard let value = try? JSONDecoder().decode(AIToolSettings.self, from: data) else { throw AIError(L("Could not read tool settings.")) }
        return value
    }

    private func write(_ value: AIToolSettings) throws -> AIToolSettings {
        do {
            try AIFileIO.write(try JSONEncoder().encode(value), to: url)
        } catch {
            throw AIError(L("Could not save tool settings."))
        }
        return value
    }

    func set(localFiles: Bool, maxOutputTokens: Int) throws -> AIToolSettings {
        guard AIToolSettings.outputLimits.contains(maxOutputTokens) else { throw AIError(L("Choose the output limit again.")) }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var value = try read()
        value.localFiles = localFiles
        value.maxOutputTokens = maxOutputTokens
        return try write(value)
    }

    /// Adds a folder chosen in the native chooser and turns local file reading on. Paths never come from the model.
    func addFolder(_ chosen: URL) throws -> AIToolSettings {
        guard let path = AIFileIO.canonicalPath(chosen.path) else { throw AIError(L("Could not find the folder.")) }
        var isDirectory: ObjCBool = false
        guard path != "/", FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AIError(L("Choose a document or project folder."))
        }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var value = try read()
        value.localFiles = true
        if !value.folders.contains(where: { $0.path == path }) {
            guard value.folders.count < 8 else { throw AIError(L("You can allow up to eight folders.")) }
            let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            value.folders.append(AIFolderGrant(id: "folder-\(nanos)", path: path))
        }
        return try write(value)
    }

    func removeFolder(_ id: String) throws -> AIToolSettings {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var value = try read()
        value.folders.removeAll { $0.id == id }
        return try write(value)
    }
}
