import Foundation
import Testing
@testable import PrismDictation

/// Ports of the Rust `dictation.rs` and TypeScript `processing.ts`/`recordingShortcuts.ts` tests.
struct SettingsTests {
    private func json(_ settings: DictationSettings) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
    }

    private func decode(_ object: [String: Any]) throws -> DictationSettings {
        try JSONDecoder().decode(DictationSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func remote(_ provider: SpeechProvider, _ base: String) -> DictationSettings {
        var settings = DictationSettings()
        settings.provider = provider
        settings.model = "whisper-1"
        settings.baseURL = base
        return settings
    }

    @Test func encodesOnlyKeysTheTauriAppAccepts() throws {
        // The Rust struct denies unknown fields, so every written key must be one it knows.
        let allowed = DictationSettings.knownKeys
        #expect(allowed.count == 24)
        var settings = DictationSettings()
        settings.cleanupModel = ProcessingSelection(provider: .vercel, model: "fixture/model", modelName: "Fixture")
        let keys = Set(try json(settings).keys)
        #expect(keys.isSubset(of: allowed))
        #expect(keys.contains("baseURL") && !keys.contains("apiKey"))
        let binding = try json(settings)["recordingCancelShortcut"] as! [String: Any]
        #expect(Set(binding.keys) == ["mode", "kind", "keyCode", "modifiers", "label"])
    }

    @Test func bothEnhancementsSurviveRoundTripWithoutChangingProfiles() throws {
        var settings = DictationSettings()
        settings.enhancementMode = .both
        settings.cleanupInstruction = "Keep names"
        settings.promptInstruction = "Keep constraints"
        settings.upgrade()
        #expect(settings.refineText)
        try settings.validate()
        var restored = try decode(try json(settings))
        restored.upgrade()
        #expect(restored.enhancementMode == .both)
        #expect(restored.cleanupInstruction == "Keep names")
        #expect(restored.promptInstruction == "Keep constraints")
        restored.enhancementMode = .prompt
        restored.upgrade()
        #expect(!restored.refineText)
    }

    @Test func migratesSharedModelOnceAndKeepsIndependentProfilesWhenOff() throws {
        var value = try json(DictationSettings())
        value.removeValue(forKey: "enhancementMode")
        value["refineText"] = true
        value["processingModel"] = ["provider": "vercel", "model": "legacy/model"]
        var settings = try decode(value)
        settings.upgrade()
        #expect(settings.enhancementMode == .cleanup)
        #expect(settings.cleanupModel?.model == "legacy/model")
        #expect(settings.promptModel?.model == "legacy/model")
        settings.enhancementMode = .off
        settings.promptModel?.model = "new/model"
        settings.promptInstruction = "Keep short paragraphs"
        settings.upgrade()
        #expect(!settings.refineText)
        #expect(settings.promptModel?.model == "new/model")
        #expect(settings.promptInstruction == "Keep short paragraphs")
        try settings.validate()
    }

    @Test func olderSettingsKeepRefinementOffAndValidateProcessingSelection() throws {
        var value = try json(DictationSettings())
        for key in ["refineText", "processingModel", "enhancementMode"] { value.removeValue(forKey: key) }
        let settings = try decode(value)
        #expect(!settings.refineText && settings.processingModel == nil)
        value["processingModel"] = ["provider": "vercel", "model": "fixture/model", "modelName": "Fixture"]
        try decode(value).validate()
        value["processingModel"] = ["provider": "vercel", "model": "bad model"]
        #expect(throws: DictationError.self) { try decode(value).validate() }
    }

    @Test func deliveryAndRecordingShortcutsValidateAndMigrate() throws {
        var value = try json(DictationSettings())
        for key in ["defaultDelivery", "saveToClipboardHistory", "recordingCancelShortcut", "recordingCopyShortcut",
                    "recordingPasteShortcut", "recordingPasteAndEnterShortcut", "showRecordingShortcutHints", "showTranscriptionStatus"] {
            value.removeValue(forKey: key)
        }
        let migrated = try decode(value)
        #expect(migrated.defaultDelivery == .paste)
        #expect(migrated.saveToClipboardHistory && migrated.showRecordingShortcutHints && migrated.showTranscriptionStatus)
        #expect(migrated.recordingCopyShortcut.mode == .disabled)
        #expect(migrated.recordingCancelShortcut == .cancelDefault && migrated.recordingPasteAndEnterShortcut == .pasteAndEnterDefault)
        var disabled = migrated
        disabled.saveToClipboardHistory = false
        #expect(try !decode(try json(disabled)).saveToClipboardHistory)
        try migrated.validate()
        var changed = migrated
        changed.defaultDelivery = .copy
        try changed.validate()
        changed.recordingPasteShortcut = changed.recordingCancelShortcut
        #expect(throws: DictationError(String(localized: "Use a different shortcut for each recording action.", bundle: .module))) { try changed.validate() }
        changed.recordingPasteShortcut.mode = .disabled
        try changed.validate()
        changed.recordingCopyShortcut.mode = .custom // custom with an empty label
        #expect(throws: DictationError.self) { try changed.validate() }
        changed.recordingCopyShortcut = RecordingShortcutSetting(mode: .sameAsPrimary, keyCode: 0, modifiers: 0, label: "")
        #expect(throws: DictationError.self) { try changed.validate() }
    }

    @Test func providerKeysCannotBeSentToCustomHosts() throws {
        #expect(throws: DictationError.self) { try remote(.openai, "https://attacker.example/v1").validate() }
        try remote(.vercel, "https://ai-gateway.vercel.sh/v4/ai").validate()
        try remote(.custom, "https://example.com/v1").validate()
        for base in ["http://example.com", "https://user:secret@example.com", "https://example.com?key=secret", "file:///tmp/audio"] {
            #expect(throws: DictationError.self) { try remote(.custom, base).validate() }
        }
        try remote(.custom, "http://127.0.0.1:9876/v1").validate()
    }

    @Test func rejectsRealtimeAndDiarizationModelsAndUnreadyLocalFiles() {
        var realtime = remote(.openai, "https://api.openai.com/v1")
        realtime.model = "gpt-realtime-whisper"
        #expect(throws: DictationError.self) { try realtime.validate() }
        realtime.model = "gpt-4o-transcribe-diarize"
        #expect(throws: DictationError.self) { try realtime.validate() }
        realtime.model = "google/gemini-3.5-transcribe-live"
        #expect(throws: DictationError.self) { try realtime.validate() }
        var defaults = DictationSettings()
        defaults.whisperPath = "/nonexistent/whisper-cli"
        #expect(throws: DictationError.self) { try defaults.preflight() }
    }

    @Test func storeWritesAtomicallyAndReadsBack() throws {
        let folder = TemporaryDirectory()
        let store = DictationSettingsStore(url: folder.url.appending(path: DictationSettingsStore.fileName))
        #expect(try store.load() == DictationSettings())
        var settings = DictationSettings()
        settings.vocabulary = ["  Prism ", "", "Whisper"]
        settings.language = "ko"
        let saved = try store.save(settings)
        #expect(saved.vocabulary == ["Prism", "Whisper"])
        #expect(try store.load() == saved)
        try Data(repeating: 32, count: 70_000).write(to: store.url)
        #expect(throws: DictationError.self) { try store.load() }
        var withKey = try json(DictationSettings())
        withKey["apiKey"] = "secret"
        try JSONSerialization.data(withJSONObject: withKey).write(to: store.url)
        #expect(throws: DictationError.self) { try store.load() }
    }

    @Test func providerChangeUsesFixedEndpointAndClearsModel() {
        var settings = DictationSettings()
        settings.model = "old"
        #expect(settings.changingProvider(to: .xai).model == "grok-stt")
        #expect(settings.changingProvider(to: .groq).baseURL == "https://api.groq.com/openai/v1")
        #expect(settings.changingProvider(to: .custom).baseURL.isEmpty)
        #expect(settings.changingProvider(to: .openai).model.isEmpty)
    }

    @Test func enhancementTogglesAreIndependent() {
        #expect(EnhancementMode.off.toggling(.cleanup) == .cleanup)
        #expect(EnhancementMode.cleanup.toggling(.prompt) == .both)
        #expect(EnhancementMode.both.toggling(.cleanup) == .prompt)
        #expect(EnhancementMode.prompt.toggling(.prompt) == .off)
    }

    @Test func effectivePromptAppendsVocabulary() {
        var settings = DictationSettings()
        settings.prompt = "Prism에서 Whisper를 사용해요."
        settings.vocabulary = ["Whisper", "Prism", "Q5"]
        #expect(settings.effectivePrompt == "Prism에서 Whisper를 사용해요.\nPrefer these proper-name spellings: Whisper, Prism, Q5")
        settings.prompt = ""
        #expect(settings.effectivePrompt == "Prefer these proper-name spellings: Whisper, Prism, Q5")
    }

    @Test func recordingKeyCaptureMatchesTheTauriRecorder() {
        let binding = RecordingShortcutSetting.keyCombination(keyCode: 9, modifierFlags: [.control, .option])
        #expect(binding == RecordingShortcutSetting(mode: .custom, keyCode: 9, modifiers: 6144, label: "⌃⌥V"))
        let control = RecordingShortcutSetting.singleModifier(.singleControl)
        #expect(control.kind == .singleControl && control.label == "⌃")
        #expect(control.conflicts(with: control))
        var disabled = control
        disabled.mode = .disabled
        #expect(!control.conflicts(with: disabled))
        #expect(RecordingShortcutSetting.keyCombination(keyCode: 200, modifierFlags: []) == nil)
        #expect(RecordingShortcutSetting.pasteDefault.displayLabel(primary: "⌃ ⌃") == "⌃ ⌃")
        #expect(RecordingShortcutSetting.copyDefault.displayLabel(primary: "⌃ ⌃") == nil)
        #expect(RecordingShortcutSetting.pasteAndEnterDefault.displayLabel(primary: nil) == "Return")
    }
}
