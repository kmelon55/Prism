import Foundation

/// The `prism-backup` JSON file, ported from `library_backup.rs`. Files made by the Tauri app import here and
/// files made here import into the Tauri app: same fields, versions, limits and error messages.
enum BackupMessage {
    static let invalid = "This backup contains invalid data. Nothing was imported."
    static let malformed = "This backup is malformed JSON. Nothing was imported."
    static let newer = "This backup uses a newer unsupported version. Update Prism before importing."
    static let unsupported = "This backup contains unsupported fields or data. Nothing was imported."
    static let stale = "The backup review expired or the library changed. Review the file again."
    static let writeError = "The backup could not be saved. The existing file was preserved."
    static let readError = "The backup file could not be read."
    static let tooLarge = "Backup files must be 20 MB or smaller."
    static let noCategory = "Select at least one backup category."
    static let keywordConflict = "A snippet keyword conflicts with another snippet. Nothing was imported."
    static let full = "The merged library exceeds its storage limit."
    static let restoreFailed = "The library could not be restored. Review the file and try again."
}

struct BackupCategories: Equatable, Sendable {
    var snippets = true
    var notes = true
    var quicklinks = true
    var pathLinks = false
    var favorites = true
    var preferences = false

    var any: Bool { snippets || notes || quicklinks || pathLinks || favorites || preferences }

    func includes(kind: String) -> Bool {
        (kind == "note" && notes) || (kind == "snippet" && snippets) || (kind == "link" && quicklinks) || (kind == "path" && pathLinks)
    }
}

/// The only preferences a backup carries. Never keys, histories, hotkeys, script folders or permission grants.
struct SafePreferences: Equatable, Sendable {
    var language: String
    var theme: String
    var reduceMotion: Bool
    var backgroundOpacity: Double
    var backgroundBlur: Double
    var showApplicationIcons: Bool
    var commandAliases: [String: String]

    static let keys: Set<String> = ["language", "theme", "reduceMotion", "backgroundOpacity", "backgroundBlur", "showApplicationIcons", "commandAliases"]

    func validate() throws {
        let unsafeID = { (id: String) in !LibraryRules.isValidID(id) || ["__proto__", "prototype", "constructor"].contains(id) }
        guard ["system", "en", "ko"].contains(language), ["system", "dark", "light"].contains(theme),
              backgroundOpacity.isFinite, (10...100).contains(backgroundOpacity),
              backgroundBlur.isFinite, (0...240).contains(backgroundBlur),
              commandAliases.count <= 1000,
              !commandAliases.contains(where: { id, alias in
                  unsafeID(id) || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || alias.utf16.count > 80 || alias.unicodeScalars.contains { $0.properties.generalCategory == .control }
              })
        else { throw BackupError(BackupMessage.invalid) }
    }
}

struct BackupEntry: Equatable, Sendable {
    var id: String
    var kind: String
    var title: String
    var value: String
    var keyword: String?
}

struct BackupFavorite: Equatable, Hashable, Sendable {
    var id: String
    var title: String
}

struct BackupDocument: Equatable, Sendable {
    static let maxBytes = 20 * 1024 * 1024

    var format = "prism-backup"
    var version: Int
    var entries: [BackupEntry]
    var favorites: [BackupFavorite]
    var preferences: SafePreferences?

    func validate() throws {
        if version > 3 { throw BackupError(BackupMessage.newer) }
        guard format == "prism-backup", [1, 2, 3].contains(version), entries.count <= LibraryRules.maxEntries,
              favorites.count <= LibraryRules.maxFavorites,
              entries.reduce(0, { $0 + $1.value.utf8.count }) <= LibraryRules.maxTotalBytes
        else { throw BackupError(BackupMessage.invalid) }
        var ids = Set<String>()
        for entry in entries {
            guard ["snippet", "note", "link", "path"].contains(entry.kind), ids.insert(entry.id).inserted,
                  entry.kind != "note" || version >= 3
            else { throw BackupError(BackupMessage.invalid) }
            do { try LibraryRules.validate(entry) } catch { throw BackupError(BackupMessage.invalid) }
        }
        var favoriteIDs = Set<String>()
        for favorite in favorites {
            guard LibraryRules.isValidID(favorite.id), !favorite.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  favorite.title.utf8.count <= 500, favoriteIDs.insert(favorite.id).inserted
            else { throw BackupError(BackupMessage.invalid) }
        }
        try preferences?.validate()
    }

    // MARK: Parsing

    /// Malformed JSON, newer versions, unknown fields and invalid records each have their own message. The version
    /// is checked before the schema, so a newer file reports the version even when it has new required fields.
    static func parse(_ data: Data) throws -> BackupDocument {
        guard data.count <= maxBytes else { throw BackupError(BackupMessage.tooLarge) }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw BackupError(BackupMessage.malformed)
        }
        guard let object = root as? [String: Any], let version = JSONValue.unsigned(object["version"]) else {
            throw BackupError(BackupMessage.invalid)
        }
        if version > 3 { throw BackupError(BackupMessage.newer) }
        if JSONValue.hasUnknownFields(object) { throw BackupError(BackupMessage.unsupported) }
        guard let document = decode(object) else { throw BackupError(BackupMessage.invalid) }
        try document.validate()
        return document
    }

    private static func decode(_ object: [String: Any]) -> BackupDocument? {
        guard let format = object["format"] as? String, let version = JSONValue.unsigned(object["version"]), version <= UInt32.max,
              let rawEntries = object["entries"] as? [Any], let rawFavorites = object["favorites"] as? [Any]
        else { return nil }
        var entries: [BackupEntry] = []
        for raw in rawEntries {
            guard let entry = raw as? [String: Any], let id = entry["id"] as? String, let kind = entry["kind"] as? String,
                  let title = entry["title"] as? String, let value = entry["value"] as? String
            else { return nil }
            let keyword: String?
            switch entry["keyword"] {
            case nil, is NSNull: keyword = nil
            case let text as String: keyword = text
            default: return nil
            }
            entries.append(BackupEntry(id: id, kind: kind, title: title, value: value, keyword: keyword))
        }
        var favorites: [BackupFavorite] = []
        for raw in rawFavorites {
            guard let favorite = raw as? [String: Any], let id = favorite["id"] as? String, let title = favorite["title"] as? String else { return nil }
            favorites.append(BackupFavorite(id: id, title: title))
        }
        var preferences: SafePreferences?
        switch object["preferences"] {
        case nil, is NSNull: preferences = nil
        case let raw as [String: Any]:
            guard let decoded = SafePreferences(json: raw) else { return nil }
            preferences = decoded
        default: return nil
        }
        return BackupDocument(format: format, version: Int(version), entries: entries, favorites: favorites, preferences: preferences)
    }

    // MARK: Encoding

    /// Pretty JSON with the same fields serde writes. Keys are sorted, which both apps accept.
    func encoded() throws -> Data {
        var object: [String: Any] = [
            "format": format,
            "version": version,
            "entries": entries.map { entry -> [String: Any] in
                var value: [String: Any] = ["id": entry.id, "kind": entry.kind, "title": entry.title, "value": entry.value]
                if let keyword = entry.keyword { value["keyword"] = keyword }
                return value
            },
            "favorites": favorites.map { ["id": $0.id, "title": $0.title] },
        ]
        object["preferences"] = preferences?.json ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

extension SafePreferences {
    /// Strict decoding: exactly the seven fields with their JSON types. Extra fields are rejected by the caller.
    init?(json raw: [String: Any]) {
        guard Set(raw.keys) == Self.keys,
              let language = raw["language"] as? String, let theme = raw["theme"] as? String,
              let reduceMotion = JSONValue.bool(raw["reduceMotion"]), let showIcons = JSONValue.bool(raw["showApplicationIcons"]),
              let opacity = JSONValue.number(raw["backgroundOpacity"]), let blur = JSONValue.number(raw["backgroundBlur"]),
              let rawAliases = raw["commandAliases"] as? [String: Any]
        else { return nil }
        var aliases: [String: String] = [:]
        for (id, value) in rawAliases {
            guard let alias = value as? String else { return nil }
            aliases[id] = alias
        }
        self.init(language: language, theme: theme, reduceMotion: reduceMotion, backgroundOpacity: opacity,
                  backgroundBlur: blur, showApplicationIcons: showIcons, commandAliases: aliases)
    }

    var json: [String: Any] {
        [
            "language": language, "theme": theme, "reduceMotion": reduceMotion,
            "backgroundOpacity": backgroundOpacity, "backgroundBlur": backgroundBlur,
            "showApplicationIcons": showApplicationIcons, "commandAliases": commandAliases,
        ]
    }
}

/// Type checks for `JSONSerialization` values, which represent booleans and numbers alike as `NSNumber`.
enum JSONValue {
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func bool(_ value: Any?) -> Bool? {
        isBool(value) ? (value as? NSNumber)?.boolValue : nil
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    /// A non-negative integer, as serde reads into `u64`. Fractions such as `2.5` are not versions.
    static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, !isBool(number), !CFNumberIsFloatType(number) else { return nil }
        return UInt64(number.stringValue)
    }

    private static let documentKeys: Set<String> = ["format", "version", "entries", "favorites", "preferences"]
    private static let entryKeys: Set<String> = ["id", "kind", "title", "value", "keyword"]
    private static let favoriteKeys: Set<String> = ["id", "title"]

    /// `deny_unknown_fields` on every struct of the document.
    static func hasUnknownFields(_ object: [String: Any]) -> Bool {
        if !Set(object.keys).isSubset(of: documentKeys) { return true }
        for entry in object["entries"] as? [Any] ?? [] {
            if let entry = entry as? [String: Any], !Set(entry.keys).isSubset(of: entryKeys) { return true }
        }
        for favorite in object["favorites"] as? [Any] ?? [] {
            if let favorite = favorite as? [String: Any], !Set(favorite.keys).isSubset(of: favoriteKeys) { return true }
        }
        if let preferences = object["preferences"] as? [String: Any], !Set(preferences.keys).isSubset(of: SafePreferences.keys) {
            return true
        }
        return false
    }
}
