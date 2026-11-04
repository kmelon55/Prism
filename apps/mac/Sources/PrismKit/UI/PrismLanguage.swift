import Foundation
import SwiftUI

/// One language preference for the shell and every feature resource bundle.
public enum PrismLanguage: String, CaseIterable, Sendable {
    case system, ko, en

    public static let didChange = Notification.Name("dev.prism.language.changed")

    public static func current(defaults: UserDefaults = .standard,
                               domain: String = Bundle.main.bundleIdentifier ?? "dev.prism.native-dev") -> Self {
        let languages = defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        guard let first = languages?.first else { return .system }
        return first.hasPrefix("ko") ? .ko : first.hasPrefix("en") ? .en : .system
    }

    public static func resolve(_ preference: Self, systemLanguages: [String]) -> String {
        if preference != .system { return preference.rawValue }
        // Match the first supported language, rather than picking Korean merely because it is in the list.
        return systemLanguages.first(where: { $0.hasPrefix("ko") || $0.hasPrefix("en") })?
            .hasPrefix("ko") == true ? "ko" : "en"
    }

    public static var identifier: String {
        // Command-line language overrides are used by isolated snapshots and tests.
        if let first = (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String])?.first {
            return resolve(.system, systemLanguages: [first])
        }
        let systemLanguages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return resolve(current(), systemLanguages: systemLanguages ?? Locale.preferredLanguages)
    }

    public static var locale: Locale { Locale(identifier: identifier) }

    @MainActor
    public static func set(_ language: Self, defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func bundle(_ bundle: Bundle, language: String) -> Bundle {
        let path = bundle.path(forResource: language, ofType: "lproj")
            ?? bundle.path(forResource: "en", ofType: "lproj")
        return path.flatMap(Bundle.init(path:)) ?? bundle
    }
}

public extension Bundle {
    /// Explicit lproj selection avoids Foundation's cached preferred language and cross-module fallback.
    var prismLocalized: Bundle { PrismLanguage.bundle(self, language: PrismLanguage.identifier) }
}

/// Rebuilds presentation when the language changes, retaining the feature's existing model and services.
public struct PrismLocalizedContent<Content: View>: View {
    @ViewState private var language = PrismLanguage.identifier
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        content()
            .environment(\.locale, Locale(identifier: language))
            .id(language)
            .onReceive(NotificationCenter.default.publisher(for: PrismLanguage.didChange)) { _ in
                language = PrismLanguage.identifier
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                language = PrismLanguage.identifier
            }
    }
}
