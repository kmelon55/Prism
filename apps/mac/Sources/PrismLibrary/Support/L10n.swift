import AppKit
import Foundation

enum L10n {
    /// Snapshot tests set a language-specific bundle, because a bare test process cannot switch languages.
    nonisolated(unsafe) static var overrideBundle: Bundle?
    static var moduleBundle: Bundle { .module }

    static func tr(_ key: String) -> String {
        if let overrideBundle { return overrideBundle.localizedString(forKey: key, value: key, table: nil) }
        return String(localized: String.LocalizationValue(key), bundle: .module)
    }
}

enum TextInputState {
    /// True while an input method (Korean, Japanese, …) has uncommitted text in the focused field.
    /// Return and shortcuts must not act on a half-composed syllable.
    @MainActor
    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}
