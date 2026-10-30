import Foundation

enum UpdateStrings {
    /// The status line under the version, from `Updates.tsx`.
    static func label(for status: UpdateStatus) -> String {
        switch status.phase {
        case .idle: String(localized: "Updates are checked automatically every six hours.", bundle: .module)
        case .development: String(localized: "Updates are disabled in development builds.", bundle: .module)
        case .checking: String(localized: "Checking for updates…", bundle: .module)
        case .current: String(localized: "Prism is up to date.", bundle: .module)
        case .available: String(localized: "A new version of Prism is available.", bundle: .module)
        case .installing: String(localized: "Downloading and installing the update…", bundle: .module)
        case .installed: String(localized: "Update installed. Restart Prism when you are ready.", bundle: .module)
        case .error: String(localized: "Could not update Prism. Check your connection and try again.", bundle: .module)
        }
    }

    /// The main button: install (or retry), restart, or check.
    static func actionTitle(for status: UpdateStatus) -> String {
        if status.canInstall { return String(localized: "Download and install", bundle: .module) }
        if status.phase == .installed { return String(localized: "Restart Prism", bundle: .module) }
        if status.phase == .installing { return String(localized: "Installing…", bundle: .module) }
        return String(localized: "Check for updates", bundle: .module)
    }
}
