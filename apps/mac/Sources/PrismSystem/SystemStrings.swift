import Foundation

enum SystemStrings {
    /// Looks up a runtime English key in the module's strings, for titles stored in tables.
    static func localized(_ english: String) -> String {
        String(localized: String.LocalizationValue(english), bundle: .module)
    }

    /// The English and Korean forms of a title, so a command is found in either language like Tauri's `bilingual`.
    static func bilingual(_ english: String) -> [String] {
        let korean = koreanBundle?.localizedString(forKey: english, value: english, table: nil) ?? english
        return korean == english ? [english] : [english, korean]
    }

    private static let koreanBundle: Bundle? = Bundle.module.path(forResource: "ko", ofType: "lproj").flatMap(Bundle.init(path:))
}
