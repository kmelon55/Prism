import PrismKit
import PrismSystem
import SwiftUI

enum GeneralSettingsPane {
    static let id = "general"

    /// `updates` is the Updates feature's section, shown at the top of General as in the Tauri app.
    @MainActor
    static func make(updates: (@MainActor () -> AnyView)?) -> SettingsPane {
        SettingsPane(id: id, title: String(localized: "General", bundle: .module), systemImage: "paintbrush.pointed",
                     order: 0, keywords: keywords) {
            GeneralSettingsView(updates: updates)
        }
    }

    static var keywords: [String] {
        ["Language", "Theme", "Prism highlights", "Background opacity", "Background blur", "Application icons", "Animations", "Launch at login", "Updates"]
            .map { String(localized: String.LocalizationValue($0), bundle: .module) }
    }
}

private struct GeneralSettingsView: View {
    let updates: (@MainActor () -> AnyView)?
    @AppStorage(PreferenceKey.theme) private var theme = ThemePreference.system.rawValue
    @AppStorage(PreferenceKey.showApplicationIcons) private var showIcons = true
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = PrismTheme.defaultBackgroundOpacity
    @AppStorage(PreferenceKey.reduceMotion) private var reduceMotion = false
    @AppStorage(PreferenceKey.prismHighlights) private var prismHighlights = false
    @AppStorage(PreferenceKey.backgroundBlur) private var backgroundBlur = Glass.defaultBlur
    @ViewState private var language = AppLanguage.current
    @ViewState private var languageChanged = false

    var body: some View {
        PrismSettingsPage(String(localized: "General", bundle: .module)) {
            if let updates { updates() }
            PrismSettingsGroup {
                LaunchAtLoginToggle()
                PrismSettingsRow(Text("Language", bundle: .module),
                                 detail: languageChanged ? Text("Applies the next time Prism opens.", bundle: .module) : nil) {
                    PrismSelect(selection: Binding(get: { language }, set: { value in
                        language = value
                        AppLanguage.set(value)
                        languageChanged = true
                    }), options: AppLanguage.allCases.map { ($0, $0.title) })
                }
            }
            PrismSettingsGroup(Text("Appearance", bundle: .module)) {
                PrismSettingsRow(Text("Theme", bundle: .module), stacked: true) {
                    PrismSegmented(selection: $theme, options: [
                        (ThemePreference.system.rawValue, ThemePreference.system.title, "circle.lefthalf.filled"),
                        (ThemePreference.dark.rawValue, ThemePreference.dark.title, "moon"),
                        (ThemePreference.light.rawValue, ThemePreference.light.title, "sun.max"),
                    ])
                }
                PrismSettingsRow(Text("Prism highlights", bundle: .module),
                                 detail: Text("Soft refracted color on selected controls.", bundle: .module)) {
                    Toggle(isOn: $prismHighlights) { EmptyView() }.toggleStyle(.prism).labelsHidden()
                }
                PrismSettingsRow(Text("Background opacity", bundle: .module)) {
                    PrismSlider(value: $backgroundOpacity, in: 0.2...1, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                }
                PrismSettingsRow(Text("Background blur", bundle: .module)) {
                    PrismSlider(value: $backgroundBlur, in: 0...32, step: 1) { "\(Int($0))px" }
                }
            }
            PrismSettingsGroup(Text("Behavior", bundle: .module)) {
                PrismSettingsRow(Text("Application icons", bundle: .module),
                                 detail: Text("Show app and file icons in results.", bundle: .module)) {
                    Toggle(isOn: $showIcons) { EmptyView() }.toggleStyle(.prism).labelsHidden()
                }
                PrismSettingsRow(Text("Animations", bundle: .module),
                                 detail: Text("Expand, collapse and fade. macOS Reduce Motion also turns them off.", bundle: .module)) {
                    Toggle(isOn: Binding(get: { !reduceMotion }, set: { reduceMotion = !$0 })) { EmptyView() }
                        .toggleStyle(.prism).labelsHidden()
                }
            }
        }
        .onChange(of: theme) { _, value in Appearance.apply(ThemePreference(rawValue: value) ?? .system) }
    }
}

/// The per-app language macOS uses (`AppleLanguages` in Prism's own defaults), read at launch.
enum AppLanguage: String, CaseIterable, Hashable {
    case system, ko, en

    var title: String {
        switch self {
        case .system: String(localized: "Follow system", bundle: .module)
        case .ko: "한국어"
        case .en: "English"
        }
    }

    static var current: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let first = (domain["AppleLanguages"] as? [String])?.first else { return .system }
        return first.hasPrefix("ko") ? .ko : first.hasPrefix("en") ? .en : .system
    }

    static func set(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

enum LauncherSettingsPane {
    static let id = "launcher"

    @MainActor
    static func make(hotKeys: CommandHotKeys) -> SettingsPane {
        SettingsPane(id: id, title: String(localized: "Launcher", bundle: .module), systemImage: "keyboard", order: 10,
                     keywords: [String(localized: "Global hotkey", bundle: .module), String(localized: "Open or hide Prism", bundle: .module)]) {
            LauncherSettingsView(hotKeys: hotKeys)
        }
    }
}

private struct LauncherSettingsView: View {
    let hotKeys: CommandHotKeys

    var body: some View {
        PrismSettingsPage(String(localized: "Launcher", bundle: .module)) {
            PrismSettingsGroup(Text("Global hotkey", bundle: .module)) {
                PrismSettingsRow(Text("Open or hide Prism", bundle: .module),
                                 detail: hotKeys.launcherError.map { Text(verbatim: $0) }) {
                    ShortcutRecorder(shortcut: Binding(
                        get: { hotKeys.launcher },
                        set: { if let shortcut = $0 { hotKeys.setLauncher(shortcut) } }
                    ))
                }
                PrismSettingsRow(Text("Shortcut", bundle: .module),
                                 detail: hotKeys.launcher == Shortcut.launcherDefault
                                     ? Text("Using the default shortcut.", bundle: .module)
                                     : Text("Using a custom shortcut.", bundle: .module)) {
                    Button {
                        hotKeys.setLauncher(Shortcut.launcherDefault)
                    } label: {
                        Label { Text("Reset", bundle: .module) } icon: { Image(systemName: "arrow.counterclockwise") }
                    }
                    .buttonStyle(.prism)
                    .disabled(hotKeys.launcher == Shortcut.launcherDefault)
                }
            }
        }
    }
}
