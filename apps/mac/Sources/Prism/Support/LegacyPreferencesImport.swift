import Foundation
import PrismCore
import PrismKit

/// Brings over, once, the settings the Tauri app kept in its WebView storage instead of the data folder: appearance,
/// the language override, command aliases and disabled commands. Values the native app already has are kept, so a
/// later change in native Settings is never replaced. Only the released app imports; development builds have their
/// own data.
@MainActor
enum LegacyPreferencesImport {
    static let doneKey = "legacyWebPreferencesImported"

    private struct Aliases: Codable {
        var version = 1
        var aliases: [String: String]
    }

    private struct Disabled: Codable {
        var version = 1
        var disabledCommandIds: [String]
    }

    static func runIfNeeded(paths: AppPaths, defaults: UserDefaults = .standard,
                            preferences: () -> [String: Any]? = { LegacyWebStorage.preferences() }) {
        guard paths.dataDirectory.lastPathComponent == AppPaths.releaseBundleIdentifier,
              !defaults.bool(forKey: doneKey) else { return }
        if let legacy = preferences() { apply(legacy, paths: paths, defaults: defaults) }
        defaults.set(true, forKey: doneKey)
    }

    static func apply(_ legacy: [String: Any], paths: AppPaths, defaults: UserDefaults) {
        func adopt(_ key: String, _ value: Any?) {
            guard let value, defaults.object(forKey: key) == nil else { return }
            defaults.set(value, forKey: key)
        }
        adopt(PreferenceKey.theme, (legacy["theme"] as? String).flatMap(ThemePreference.init(rawValue:))?.rawValue)
        for key in [PreferenceKey.reduceMotion, PreferenceKey.showApplicationIcons, PreferenceKey.prismHighlights, "openingLightAnimation"] {
            adopt(key, legacy[key] as? Bool)
        }
        // Tauri kept the tint in percent and the blur in points.
        adopt(PreferenceKey.backgroundOpacity, (legacy["backgroundOpacity"] as? Double).map { min(max($0 / 100, 0.2), 1) })
        adopt(PreferenceKey.backgroundBlur, (legacy["backgroundBlur"] as? Double).map { min(max($0, 0), 32) })
        if let language = legacy["language"] as? String, ["en", "ko"].contains(language),
           defaults.persistentDomain(forName: AppPaths.releaseBundleIdentifier)?["AppleLanguages"] == nil {
            defaults.set([language], forKey: "AppleLanguages")
        }

        let aliasStore = JSONFileStore<Aliases>(url: paths.file("command-aliases-v1.json"))
        if let raw = legacy["commandAliases"] as? [String: Any], !FileManager.default.fileExists(atPath: aliasStore.url.path) {
            let aliases = Dictionary(raw.compactMap { id, alias in (alias as? String).map { (nativeID(id), $0) } },
                                     uniquingKeysWith: { first, _ in first })
            if !aliases.isEmpty { try? aliasStore.save(Aliases(aliases: aliases)) }
        }
        let disabledStore = JSONFileStore<Disabled>(url: paths.file("disabled-commands-v1.json"))
        if let raw = legacy["disabledCommandIds"] as? [Any], !FileManager.default.fileExists(atPath: disabledStore.url.path) {
            let ids = raw.compactMap { $0 as? String }.map(nativeID)
            if !ids.isEmpty { try? disabledStore.save(Disabled(disabledCommandIds: ids)) }
        }
    }

    /// Tauri named applications `native:<hex path>`; the native catalog uses `app:<path>`.
    static func nativeID(_ id: String) -> String {
        guard id.hasPrefix("native:"), let path = Frecency.path(fromApplicationID: String(id.dropFirst("native:".count))) else { return id }
        return UsageStore.applicationPrefix + path
    }
}
