import AppKit
import PrismKit

/// UserDefaults keys shared by `@AppStorage` views and AppKit controllers.
enum PreferenceKey {
    static let theme = "theme"
    static let showApplicationIcons = "showApplicationIcons"
    /// Shell tint over the glass, 0.2...1. The Tauri default is 0.64.
    static let backgroundOpacity = "backgroundOpacity"
    /// Turns off Prism's own expand, collapse and fade animations (the Tauri "Animations" switch, inverted).
    static let reduceMotion = "reduceMotion"
    /// Glass blur radius in points, 0...32 (Tauri default 12). Zero shows the tint without glass.
    static let backgroundBlur = "backgroundBlur"
    static let prismHighlights = PrismHighlights.key
}

enum Glass {
    static let defaultBlur = 12.0

    static var blur: Double {
        (UserDefaults.standard.object(forKey: PreferenceKey.backgroundBlur) as? Double) ?? defaultBlur
    }
}

enum Motion {
    /// The system Reduce Motion setting or Prism's own Animations switch.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: PreferenceKey.reduceMotion)
    }
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System", bundle: .module)
        case .light: String(localized: "Light", bundle: .module)
        case .dark: String(localized: "Dark", bundle: .module)
        }
    }
}

enum Appearance {
    @MainActor
    static func apply(_ theme: ThemePreference) {
        NSApp.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyStoredTheme() {
        apply(ThemePreference(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.theme) ?? "") ?? .system)
    }
}
