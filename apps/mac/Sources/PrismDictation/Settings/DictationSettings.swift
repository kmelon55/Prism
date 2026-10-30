import Foundation
import PrismKit

/// Speech-to-text providers. Raw values are the `provider` strings stored in `dictation-v1.json`.
enum SpeechProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, openai, vercel, groq, xai, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local · whisper.cpp"
        case .openai: "OpenAI"
        case .vercel: "Vercel AI Gateway"
        case .groq: "Groq"
        case .xai: "xAI"
        case .custom: String(localized: "OpenAI-compatible", bundle: .module)
        }
    }

    var shortTitle: String {
        switch self {
        case .local: String(localized: "Local", bundle: .module)
        case .vercel: "Vercel"
        default: title
        }
    }

    /// Built-in providers only accept their own host, so a stored key is never sent elsewhere.
    var fixedBaseURL: String? {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .vercel: "https://ai-gateway.vercel.sh/v4/ai"
        case .groq: "https://api.groq.com/openai/v1"
        case .xai: "https://api.x.ai/v1"
        case .local, .custom: nil
        }
    }
}

/// Text-processing providers. Raw values match the AI settings' providers (`ai::Provider`, lowercase).
enum TextProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, openrouter, vercel, compatible
    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .vercel: "Vercel AI Gateway"
        case .compatible: String(localized: "OpenAI-compatible", bundle: .module)
        }
    }
}

struct ProcessingSelection: Codable, Equatable, Sendable {
    var provider: TextProvider
    var model: String
    var modelName: String?

    var isValid: Bool {
        !model.isEmpty && model.utf8.count <= 200 && model.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
            && (modelName.map { $0.utf8.count <= 720 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } } ?? true)
    }
}

enum EnhancementMode: String, Codable, CaseIterable, Sendable {
    case off, cleanup, prompt, both

    func includes(_ feature: ProcessingMode) -> Bool {
        switch feature {
        case .cleanup: self == .cleanup || self == .both
        case .prompt: self == .prompt || self == .both
        }
    }

    /// Turns one enhancement on or off without touching the other.
    func toggling(_ feature: ProcessingMode) -> EnhancementMode {
        let other: ProcessingMode = feature == .cleanup ? .prompt : .cleanup
        if includes(feature) { return includes(other) ? EnhancementMode(other) : .off }
        return includes(other) ? .both : EnhancementMode(feature)
    }

    private init(_ feature: ProcessingMode) { self = feature == .cleanup ? .cleanup : .prompt }
}

enum ProcessingMode: String, Sendable {
    case cleanup, prompt
}

enum DefaultDelivery: String, Codable, CaseIterable, Sendable {
    case copy, paste
}

/// `dictation-v1.json`. Field names and defaults follow `apps/desktop/src-tauri/src/dictation.rs`, which rejects
/// unknown fields, so never add keys here. API keys are never part of this file.
struct DictationSettings: Codable, Equatable, Sendable {
    var enhancementMode: EnhancementMode?
    var cleanupModel: ProcessingSelection?
    var promptModel: ProcessingSelection?
    var cleanupInstruction: String
    var promptInstruction: String
    var refineText: Bool
    var processingModel: ProcessingSelection?
    var provider: SpeechProvider
    var model: String
    var baseURL: String
    var language: String
    var prompt: String
    var vocabulary: [String]
    var whisperPath: String
    var modelPath: String
    var uiLanguage: String
    var showRecordingShortcutHints: Bool
    var showTranscriptionStatus: Bool
    var defaultDelivery: DefaultDelivery
    var saveToClipboardHistory: Bool
    var recordingCancelShortcut: RecordingShortcutSetting
    var recordingCopyShortcut: RecordingShortcutSetting
    var recordingPasteShortcut: RecordingShortcutSetting
    var recordingPasteAndEnterShortcut: RecordingShortcutSetting

    static let defaultWhisperPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli")
        ? "/opt/homebrew/bin/whisper-cli" : "/usr/local/bin/whisper-cli"

    init() {
        enhancementMode = .off
        cleanupInstruction = ProcessingPrompts.cleanup
        promptInstruction = ProcessingPrompts.prompt
        refineText = false
        provider = .local
        model = ""
        baseURL = ""
        language = "auto"
        prompt = ""
        vocabulary = []
        whisperPath = Self.defaultWhisperPath
        modelPath = ""
        uiLanguage = Locale.preferredLanguages.first?.hasPrefix("ko") == true ? "ko" : "en"
        showRecordingShortcutHints = true
        showTranscriptionStatus = true
        defaultDelivery = .paste
        saveToClipboardHistory = true
        recordingCancelShortcut = .cancelDefault
        recordingCopyShortcut = .copyDefault
        recordingPasteShortcut = .pasteDefault
        recordingPasteAndEnterShortcut = .pasteAndEnterDefault
    }

    private enum CodingKeys: String, CodingKey {
        case enhancementMode, cleanupModel, promptModel, cleanupInstruction, promptInstruction, refineText, processingModel
        case provider, model, baseURL, language, prompt, vocabulary, whisperPath, modelPath, uiLanguage
        case showRecordingShortcutHints, showTranscriptionStatus, defaultDelivery, saveToClipboardHistory
        case recordingCancelShortcut, recordingCopyShortcut, recordingPasteShortcut, recordingPasteAndEnterShortcut
    }

    static let knownKeys: Set<String> = [
        "enhancementMode", "cleanupModel", "promptModel", "cleanupInstruction", "promptInstruction", "refineText", "processingModel",
        "provider", "model", "baseURL", "language", "prompt", "vocabulary", "whisperPath", "modelPath", "uiLanguage",
        "showRecordingShortcutHints", "showTranscriptionStatus", "defaultDelivery", "saveToClipboardHistory",
        "recordingCancelShortcut", "recordingCopyShortcut", "recordingPasteShortcut", "recordingPasteAndEnterShortcut",
    ]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DictationSettings()
        enhancementMode = try c.decodeIfPresent(EnhancementMode.self, forKey: .enhancementMode)
        cleanupModel = try c.decodeIfPresent(ProcessingSelection.self, forKey: .cleanupModel)
        promptModel = try c.decodeIfPresent(ProcessingSelection.self, forKey: .promptModel)
        cleanupInstruction = try c.decodeIfPresent(String.self, forKey: .cleanupInstruction) ?? defaults.cleanupInstruction
        promptInstruction = try c.decodeIfPresent(String.self, forKey: .promptInstruction) ?? defaults.promptInstruction
        refineText = try c.decodeIfPresent(Bool.self, forKey: .refineText) ?? false
        processingModel = try c.decodeIfPresent(ProcessingSelection.self, forKey: .processingModel)
        provider = try c.decode(SpeechProvider.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        language = try c.decode(String.self, forKey: .language)
        prompt = try c.decode(String.self, forKey: .prompt)
        vocabulary = try c.decode([String].self, forKey: .vocabulary)
        whisperPath = try c.decode(String.self, forKey: .whisperPath)
        modelPath = try c.decode(String.self, forKey: .modelPath)
        uiLanguage = try c.decode(String.self, forKey: .uiLanguage)
        showRecordingShortcutHints = try c.decodeIfPresent(Bool.self, forKey: .showRecordingShortcutHints) ?? true
        showTranscriptionStatus = try c.decodeIfPresent(Bool.self, forKey: .showTranscriptionStatus) ?? true
        defaultDelivery = try c.decodeIfPresent(DefaultDelivery.self, forKey: .defaultDelivery) ?? .paste
        saveToClipboardHistory = try c.decodeIfPresent(Bool.self, forKey: .saveToClipboardHistory) ?? true
        recordingCancelShortcut = try c.decodeIfPresent(RecordingShortcutSetting.self, forKey: .recordingCancelShortcut) ?? .cancelDefault
        recordingCopyShortcut = try c.decodeIfPresent(RecordingShortcutSetting.self, forKey: .recordingCopyShortcut) ?? .copyDefault
        recordingPasteShortcut = try c.decodeIfPresent(RecordingShortcutSetting.self, forKey: .recordingPasteShortcut) ?? .pasteDefault
        recordingPasteAndEnterShortcut = try c.decodeIfPresent(RecordingShortcutSetting.self, forKey: .recordingPasteAndEnterShortcut) ?? .pasteAndEnterDefault
    }

    /// Migrates the legacy single `processingModel` into both enhancement profiles once.
    mutating func upgrade() {
        if enhancementMode == nil {
            enhancementMode = refineText ? .cleanup : processingModel != nil ? .prompt : .off
            cleanupModel = processingModel
            promptModel = processingModel
        }
        refineText = mode.includes(.cleanup)
    }

    var mode: EnhancementMode { enhancementMode ?? .off }

    func selection(for mode: ProcessingMode) -> ProcessingSelection? {
        if enhancementMode == nil { return processingModel }
        return mode == .prompt ? promptModel : cleanupModel
    }

    func instruction(for mode: ProcessingMode) -> String {
        mode == .prompt ? promptInstruction : cleanupInstruction
    }

    /// Prompt sent to the recognizer: the user's hint followed by preferred spellings.
    var effectivePrompt: String {
        guard !vocabulary.isEmpty else { return prompt }
        let hint = "Prefer these proper-name spellings: " + vocabulary.joined(separator: ", ")
        return [prompt, hint].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var recordingBindings: [RecordingShortcutSetting] {
        [recordingCancelShortcut, recordingPasteShortcut, recordingPasteAndEnterShortcut, recordingCopyShortcut]
    }

    func binding(_ action: RecordingAction) -> RecordingShortcutSetting {
        switch action {
        case .cancel: recordingCancelShortcut
        case .copy: recordingCopyShortcut
        case .paste: recordingPasteShortcut
        case .send: recordingPasteAndEnterShortcut
        }
    }

    mutating func setBinding(_ binding: RecordingShortcutSetting, for action: RecordingAction) {
        switch action {
        case .cancel: recordingCancelShortcut = binding
        case .copy: recordingCopyShortcut = binding
        case .paste: recordingPasteShortcut = binding
        case .send: recordingPasteAndEnterShortcut = binding
        }
    }

    /// Switching provider clears the model and uses the provider's fixed endpoint.
    func changingProvider(to provider: SpeechProvider) -> DictationSettings {
        var next = self
        next.provider = provider
        next.model = provider == .xai ? "grok-stt" : ""
        next.baseURL = provider.fixedBaseURL ?? ""
        return next
    }

    /// The same checks as the Rust `validate`, so a file this app writes always loads in the Tauri app.
    func validate() throws {
        for selection in [processingModel, cleanupModel, promptModel].compactMap({ $0 }) where !selection.isValid {
            throw DictationError(String(localized: "Choose a text processing model.", bundle: .module))
        }
        for text in [cleanupInstruction, promptInstruction] where text.utf8.count > 8000 || text.contains("\0") {
            throw DictationError(String(localized: "Processing prompt is too long.", bundle: .module))
        }
        if let message = RecordingShortcutSetting.validationError(recordingBindings) { throw DictationError(message) }
        let invalidWord = vocabulary.contains { $0.utf8.count > 200 || $0.contains(where: { "\r\n\0".contains($0) }) }
        if model.utf8.count > 200 || prompt.utf8.count > 8000 || vocabulary.count > 100 || invalidWord
            || whisperPath.utf8.count > 4096 || modelPath.utf8.count > 4096 || whisperPath.contains("\0") || modelPath.contains("\0")
            || !["ko", "en"].contains(uiLanguage) || language.isEmpty || language.utf8.count > 16
            || !language.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.letters.contains($0)) || $0 == "-" }) {
            throw DictationError(String(localized: "Some dictation settings are invalid.", bundle: .module))
        }
        guard provider != .local else { return }
        let lowered = model.lowercased()
        if model.isEmpty || !model.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 })
            || lowered.contains("realtime") || model.hasSuffix("-live") || (provider == .openai && model.contains("diarize")) {
            throw DictationError(String(localized: "Choose a speech model that supports file transcription.", bundle: .module))
        }
        try Self.validateEndpoint(baseURL)
        if let expected = provider.fixedBaseURL, baseURL.trimmingTrailing("/") != expected {
            throw DictationError(String(localized: "The provider API address is not valid. Choose OpenAI-compatible for other servers.", bundle: .module))
        }
    }

    static func validateEndpoint(_ baseURL: String) throws {
        guard let components = URLComponents(string: baseURL), let scheme = components.scheme, let host = components.host, !host.isEmpty,
              baseURL.utf8.count <= 2048, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else {
            throw DictationError(String(localized: "Enter an HTTPS URL or a local HTTP address. Do not put credentials or queries in the URL.", bundle: .module))
        }
    }

    /// Checks that the files and executable needed to start a recording exist.
    func preflight() throws {
        try validate()
        guard provider == .local else { return }
        var isDirectory: ObjCBool = false
        guard whisperPath.hasPrefix("/"), FileManager.default.fileExists(atPath: whisperPath, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: whisperPath) else {
            throw DictationError(String(localized: "Choose an executable whisper.cpp file.", bundle: .module))
        }
        guard modelPath.hasPrefix("/"), FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DictationError(String(localized: "Choose a local Whisper model file.", bundle: .module))
        }
    }
}

/// Reads and atomically writes `dictation-v1.json` in the app data folder.
struct DictationSettingsStore: Sendable {
    static let fileName = "dictation-v1.json"
    let url: URL

    init(url: URL) { self.url = url }
    init(paths: AppPaths) { url = paths.dataDirectory.appending(path: Self.fileName) }

    func load() throws -> DictationSettings {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return DictationSettings() }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 65_536, let data = try? Data(contentsOf: url) else {
            throw DictationError(String(localized: "Could not read dictation settings.", bundle: .module))
        }
        // Like the Rust reader, reject unknown fields such as a stray `apiKey`.
        let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys
        guard let keys, Set(keys).isSubset(of: DictationSettings.knownKeys),
              var settings = try? JSONDecoder().decode(DictationSettings.self, from: data) else {
            throw DictationError(String(localized: "The dictation settings file is not valid.", bundle: .module))
        }
        settings.upgrade()
        try settings.validate()
        return settings
    }

    func save(_ settings: DictationSettings) throws -> DictationSettings {
        var settings = settings
        settings.upgrade()
        settings.vocabulary = settings.vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try settings.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        return settings
    }
}

struct DictationError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension String {
    func trimmingTrailing(_ character: Character) -> String {
        var value = self
        while value.last == character { value.removeLast() }
        return value
    }
}
