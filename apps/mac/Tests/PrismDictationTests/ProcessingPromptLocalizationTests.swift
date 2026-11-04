import Testing
@testable import PrismDictation

struct ProcessingPromptLocalizationTests {
    @Test func builtInInstructionsFollowTheAppLanguage() {
        for mode in [ProcessingMode.cleanup, .prompt] {
            let english = ProcessingPrompts.defaultInstruction(mode)
            let korean = ProcessingPrompts.displayInstruction(mode, stored: english, language: "ko")
            #expect(korean != english)
            #expect(ProcessingPrompts.isDefaultInstruction(mode, stored: korean))
            #expect(ProcessingPrompts.displayInstruction(mode, stored: korean, language: "en") == english)
        }
    }

    @Test func customInstructionsAreNeverTranslatedOrOverwritten() {
        for custom in ["Use short paragraphs.", "고유명사는 그대로 두고 정리해주세요."] {
            for language in ["en", "ko"] {
                #expect(ProcessingPrompts.displayInstruction(.cleanup, stored: custom, language: language) == custom)
                #expect(!ProcessingPrompts.isDefaultInstruction(.cleanup, stored: custom))
            }
        }
    }
}
