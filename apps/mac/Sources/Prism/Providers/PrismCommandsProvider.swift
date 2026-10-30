import AppKit
import PrismCore
import PrismKit

/// The shell's own commands, with the Tauri IDs: Settings, appearance, hide, quit and application index maintenance.
@MainActor
final class PrismCommandsProvider: PaletteProvider {
    let id = "prism"
    private let openSettings: () -> Void
    private let refreshApplications: () -> Void

    init(openSettings: @escaping () -> Void, refreshApplications: @escaping () -> Void) {
        self.openSettings = openSettings
        self.refreshApplications = refreshApplications
    }

    func results(for query: String) async -> [PaletteItem] {
        let prism = "Prism"
        let maintenance = String(localized: "Prism maintenance", bundle: .module)
        return [
            command("prism:preferences", String(localized: "Prism Settings", bundle: .module),
                    String(localized: "Make the palette feel native to you", bundle: .module), "gearshape", prism,
                    ["settings", "preferences", "설정", "환경설정"], hidden: true) { [openSettings] in
                openSettings()
                return .dismiss
            },
            command("prism:cycle-theme", String(localized: "Cycle Appearance", bundle: .module),
                    String(localized: "System → dark → light", bundle: .module), "circle.lefthalf.filled", prism,
                    ["theme", "dark", "light", "system", "appearance", "테마", "다크", "라이트"], hidden: true) {
                let current = ThemePreference(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.theme) ?? "") ?? .system
                let next: ThemePreference = switch current {
                case .system: .dark
                case .dark: .light
                case .light: .system
                }
                UserDefaults.standard.set(next.rawValue, forKey: PreferenceKey.theme)
                Appearance.apply(next)
                return .notify(next.title)
            },
            command("prism:hide", String(localized: "Hide Prism", bundle: .module),
                    String(localized: "Keep Prism ready in the background", bundle: .module), "eye.slash", prism,
                    ["hide", "close", "숨기기"], hidden: true) { .dismiss },
            command("prism:quit", String(localized: "Quit Prism", bundle: .module),
                    String(localized: "Stop Prism and its background shortcuts", bundle: .module), "power", prism,
                    ["quit", "exit", "종료"], hidden: true) {
                NSApp.terminate(nil)
                return .dismiss
            },
            command("prism:refresh-application-index", String(localized: "Refresh application index", bundle: .module),
                    String(localized: "Find recently installed or removed applications", bundle: .module),
                    "arrow.clockwise", maintenance, ["refresh", "rescan", "apps", "새로고침"], hidden: true) { [refreshApplications] in
                refreshApplications()
                return .notify(String(localized: "Refreshing applications…", bundle: .module))
            },
            command("prism:clear-application-icon-cache", String(localized: "Clear application icon cache", bundle: .module),
                    String(localized: "Discard locally saved application artwork", bundle: .module),
                    "photo.badge.arrow.down", maintenance, ["icon", "cache", "clear", "아이콘", "캐시"], hidden: true) {
                AppIconCache.shared.removeAll()
                return .notify(String(localized: "Icon cache cleared", bundle: .module))
            },
        ]
    }

    /// `hidden` keeps rare commands out of the empty query; typing finds them.
    private func command(
        _ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ section: String, _ keywords: [String],
        hidden: Bool = false, run: @escaping @MainActor () async -> PaletteActionOutcome
    ) -> PaletteItem {
        PaletteItem(
            candidate: SearchCandidate(id: id, title: title, subtitle: subtitle, section: section, keywords: keywords),
            icon: .symbol(symbol),
            accessory: String(localized: "Command", bundle: .module),
            actions: [PaletteAction(id: id, title: title, systemImage: symbol, run: run)],
            hiddenWhenQueryIsEmpty: hidden
        )
    }
}
