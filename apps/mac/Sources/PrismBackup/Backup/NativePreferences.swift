import Foundation
import PrismKit

/// User command aliases in `command-aliases-v1.json`: `{"version":1,"aliases":{"<command id>":"<alias>"}}`.
///
/// The Tauri app kept these in WebView storage (`commandAliases`). The native shell has no alias store yet, so
/// backups and the Raycast import keep them here, in the shape the shell is asked to adopt (see the report).
/// A malformed file is never overwritten.
struct CommandAliasStore: Sendable {
    static let fileName = "command-aliases-v1.json"
    static let malformed = "Saved command aliases could not be read. They were left unchanged."

    let url: URL

    func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try BackupFiles.read(url, limit: 1024 * 1024, readError: Self.malformed, invalidError: Self.malformed, tooLarge: Self.malformed)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], JSONValue.number(object["version"]) == 1,
              let raw = object["aliases"] as? [String: Any]
        else { throw BackupError(Self.malformed) }
        var aliases: [String: String] = [:]
        for (id, value) in raw {
            guard let alias = value as? String else { throw BackupError(Self.malformed) }
            aliases[id] = alias
        }
        return aliases
    }

    func save(_ aliases: [String: String]) throws {
        _ = try load()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "aliases": aliases], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupFiles.write(data, to: url, writeError: "Could not save command aliases.")
    }
}

/// Where the native app keeps each safe preference.
///
/// - `theme` and `showApplicationIcons`: the shell's `UserDefaults` keys of the same names, same values.
/// - `language`: the per-app language macOS itself uses (`AppleLanguages` in Prism's own defaults domain), which
///   applies the next time Prism opens. `system` removes the override.
/// - `commandAliases`: `CommandAliasStore`.
/// - `reduceMotion` and `backgroundOpacity`: the shell's own keys (`reduceMotion`; `backgroundOpacity` as 0.1...1,
///   where the backup file uses percent).
/// - `backgroundBlur`: the shell's glass blur radius in points, the same scale as the backup file.
@MainActor
struct NativePreferences {
    let defaults: UserDefaults
    /// The persistent domain that holds Prism's own settings (the bundle identifier, or a test suite name).
    let domain: String
    let aliases: CommandAliasStore

    private enum Key {
        static let theme = "theme"
        static let showApplicationIcons = "showApplicationIcons"
        static let language = "AppleLanguages"
        static let reduceMotion = "reduceMotion"
        static let backgroundOpacity = "backgroundOpacity"
        static let backgroundBlur = "backgroundBlur"
    }

    func current() throws -> SafePreferences {
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        let languages = stored[Key.language] as? [String] ?? []
        let language = languages.first.map { $0.hasPrefix("ko") ? "ko" : $0.hasPrefix("en") ? "en" : "system" } ?? "system"
        let theme = defaults.string(forKey: Key.theme).flatMap { ["system", "light", "dark"].contains($0) ? $0 : nil } ?? "system"
        let opacity = (stored[Key.backgroundOpacity] as? Double).map { ($0 * 100).rounded() }
            .flatMap { (10...100).contains($0) ? $0 : nil } ?? SafePreferencesMerge.defaultOpacity
        let blur = (stored[Key.backgroundBlur] as? Double).flatMap { (0...SafePreferencesMerge.maxBlur).contains($0) ? $0 : nil }
            ?? SafePreferencesMerge.defaultBlur
        // Aliases that cannot be backed up (too long, unsafe IDs) stay out of the file rather than failing the export.
        let aliases = try aliases.load().filter { id, alias in
            (try? SafePreferences(language: "system", theme: "system", reduceMotion: false, backgroundOpacity: 64, backgroundBlur: 12,
                                  showApplicationIcons: true, commandAliases: [id: alias]).validate()) != nil
        }
        return SafePreferences(
            language: language, theme: theme, reduceMotion: stored[Key.reduceMotion] as? Bool ?? false,
            backgroundOpacity: opacity, backgroundBlur: blur,
            showApplicationIcons: defaults.object(forKey: Key.showApplicationIcons) as? Bool ?? true,
            commandAliases: Dictionary(uniqueKeysWithValues: aliases.prefix(SafePreferencesMerge.maxAliases).map { ($0.key, $0.value) })
        )
    }

    /// Writes the merged preferences. Aliases are saved first, because they are the only part that can fail, so a
    /// failure leaves appearance and language untouched too.
    func restore(_ preferences: SafePreferences) throws {
        try preferences.validate()
        try aliases.save(preferences.commandAliases)
        defaults.set(preferences.theme, forKey: Key.theme)
        defaults.set(preferences.showApplicationIcons, forKey: Key.showApplicationIcons)
        if preferences.language == "system" {
            defaults.removeObject(forKey: Key.language)
        } else {
            defaults.set([preferences.language], forKey: Key.language)
        }
        defaults.set(preferences.reduceMotion, forKey: Key.reduceMotion)
        defaults.set(preferences.backgroundOpacity / 100, forKey: Key.backgroundOpacity)
        defaults.set(preferences.backgroundBlur, forKey: Key.backgroundBlur)
    }
}
