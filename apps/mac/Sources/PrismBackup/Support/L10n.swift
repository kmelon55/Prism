import Foundation

enum L10n {
    /// Snapshot tests set a language-specific bundle, because a bare test process cannot switch languages.
    nonisolated(unsafe) static var overrideBundle: Bundle?

    /// Translates an English message, including the error strings this module keeps in English like the Tauri app.
    static func tr(_ key: String) -> String {
        if let overrideBundle { return overrideBundle.localizedString(forKey: key, value: key, table: nil) }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    /// `tr` for a key with `%@` or `%lld` placeholders.
    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: tr(key), arguments: arguments)
    }
}

/// An error whose message is one of the English sentences the Tauri app shows; the UI translates it.
struct BackupError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { L10n.tr(message) }
}
