import PrismKit
import Foundation

enum UpdateStrings {
    /// The status line under the version, from `Updates.tsx`.
    static func label(for status: UpdateStatus) -> String {
        switch status.phase {
        case .idle: String(localized: "Updates are checked automatically every six hours.", bundle: .module.prismLocalized)
        case .development: String(localized: "Updates are disabled in development builds.", bundle: .module.prismLocalized)
        case .checking: String(localized: "Checking for updates…", bundle: .module.prismLocalized)
        case .current: String(localized: "Prism is up to date.", bundle: .module.prismLocalized)
        case .available: String(localized: "A new version of Prism is available.", bundle: .module.prismLocalized)
        case .installing: String(localized: "Downloading and installing the update…", bundle: .module.prismLocalized)
        case .installed: String(localized: "Update installed. Restart Prism when you are ready.", bundle: .module.prismLocalized)
        case .error: String(localized: "Could not update Prism. Check your connection and try again.", bundle: .module.prismLocalized)
        }
    }

    /// The main button: install (or retry), restart, or check.
    static func actionTitle(for status: UpdateStatus) -> String {
        if status.canInstall { return String(localized: "Download and install", bundle: .module.prismLocalized) }
        if status.phase == .installed { return String(localized: "Restart Prism", bundle: .module.prismLocalized) }
        if status.phase == .installing { return String(localized: "Installing…", bundle: .module.prismLocalized) }
        return String(localized: "Check for updates", bundle: .module.prismLocalized)
    }
}
