import Foundation

/// A recognized request that cannot be answered, such as `1 kg to cm`. The palette shows the message as a
/// non-actionable row, where the Tauri app showed a provider failure notice.
struct AnswerError: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
