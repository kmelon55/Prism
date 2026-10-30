import SwiftUI

/// The AI model catalog picker, lent by the AI feature to features that also call text models (dictation's
/// processing model), so every model choice uses the same searchable dialog without the modules importing each other.
@MainActor
public enum SharedModelPicker {
    public struct Choice: Equatable, Sendable {
        /// The AI provider's raw value: `vercel`, `openai`, `openrouter` or `compatible`.
        public var provider: String
        public var model: String
        public var modelName: String?

        public init(provider: String, model: String, modelName: String? = nil) {
            self.provider = provider
            self.model = model
            self.modelName = modelName
        }
    }

    /// Builds the picker for a title, the current choice, a save handler and a close handler. Nil until the AI
    /// feature registers it.
    public static var make: ((_ title: String, _ current: Choice?, _ onSelect: @escaping @MainActor (Choice) async throws -> Void,
                              _ onDismiss: @escaping @MainActor () -> Void) -> AnyView)?
}
