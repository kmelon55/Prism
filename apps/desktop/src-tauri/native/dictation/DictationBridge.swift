// Whisp recording, waveform and text delivery adapted for Prism. See LICENSE-Whisp.
import AppKit
import AVFoundation
import SwiftUI

struct AppLanguage {
    var english = false
    func text(_ korean: String, _ english: String) -> String { self.english ? english : korean }
}
enum RemoteProvider: String, Decodable { case openAI = "openai", vercel, xAI = "xai", groq, custom }
struct RemoteConfiguration { let provider: RemoteProvider; let apiKey: String; let baseURL: String; let model: String }
struct DictationConfiguration: Decodable {
    let provider: String
    let model: String
    let baseURL: String
    let language: String
    let prompt: String
    let vocabulary: [String]
    let whisperPath: String
    let modelPath: String
    let uiLanguage: String
    let apiKey: String
    var refineText: Bool?
    var processingModel: ProcessingSelection?
    var enhancementMode: String?
    var processingPrompt: String?
    var effectivePrompt: String {
        guard !vocabulary.isEmpty else { return prompt }
        let hint = "Prefer these proper-name spellings: " + vocabulary.joined(separator: ", ")
        return [prompt, hint].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
struct DictationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
typealias DictationCallback = @convention(c) (UnsafePointer<CChar>) -> Void

@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()
    @Published var phase = "idle"
    @Published var amplitude = 0.0
    @Published var message = ""
    var language = AppLanguage()
    var callback: DictationCallback?
    private lazy var overlay = OverlayPresenter(appState: self)
    var overlaySettings = OverlaySettings()
    @Published var overlayPreviewPhase: String?
    private let controls = RecordingControls()
    var recordingHints: [RecordingOverlayHint] {
        [UInt32(1), 4, 3, 2].compactMap { id in
            let binding = overlaySettings.binding(id)
            guard controls.registered(id) || overlayPreviewPhase != nil || (id == 3 && binding.mode == .sameAsPrimary), let key = overlaySettings.label(id) else { return nil }
            let label = id == 1 ? language.text("취소", "Cancel") : id == 2 ? language.text("전송", "Send") : id == 4 ? language.text("복사", "Copy") : binding.mode == .sameAsPrimary && overlaySettings.defaultDelivery == "copy" ? language.text("복사", "Copy") : language.text("붙여넣기", "Paste")
            return RecordingOverlayHint(id: String(id), key: key, label: label)
        }
    }
    private let recorder: any DictationRecording
    private let presentsOverlay: Bool
    private let deliver: (String, Bool, Bool, TextInsertionTarget?) async -> TextDeliveryResult
    private var target: TextInsertionTarget?
    private var transcriptionAudio: URL?
    private var configuration: DictationConfiguration?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var monitor: Any?
    private var localMonitor: Any?
    private var generation: UInt64 = 0
    private var lastTranscript = ""
    private var originalTranscript = ""
    var processingMode = "none"
    private var processingContinuation: CheckedContinuation<ProcessingResult, Never>?
    private var receipt = UsageReceipt()
    private var refinementWarning = ""


    init(recorder suppliedRecorder: (any DictationRecording)? = nil, presentsOverlay: Bool = true, deliver: @escaping (String, Bool, Bool, TextInsertionTarget?) async -> TextDeliveryResult = { text, paste, enter, target in await TextInjector.deliver(text, paste: paste, pressEnterAfterPaste: enter, target: target) }) {
        let recorder = suppliedRecorder ?? AudioRecorder()
        self.recorder = recorder; self.presentsOverlay = presentsOverlay; self.deliver = deliver
        recorder.onLevel = { [weak self] level in self?.amplitude = level }
        recorder.onFailure = { [weak self] message in self?.fail(message) }
    }
    private var permissionForControls: Bool?
    private var microphoneRequestPending = false
    func refreshPermissions() {
        let granted = AXIsProcessTrusted()
        if permissionForControls != granted {
            permissionForControls = granted
            if presentsOverlay && busy { controls.install(recording: phase == "recording") }
        }
        emit()
    }
    func requestMicrophonePermission() {
        guard !microphoneRequestPending else { return }
        microphoneRequestPending = true
        Task { @MainActor in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneRequestPending = false; emit()
        }
        emit()
    }
    var busy: Bool { ["preparing", "recording", "transcribing", "processing", "inserting"].contains(phase) }
    func emit(action: String? = nil) {
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "granted"
        case .notDetermined: permission = "notDetermined"
        case .denied: permission = "denied"
        default: permission = "restricted"
        }
        var value: [String: Any] = ["phase": phase, "message": message, "microphone": permission,
            "accessibility": AXIsProcessTrusted(), "hasTranscript": !lastTranscript.isEmpty, "hasOriginal": !originalTranscript.isEmpty, "processingMode": processingMode, "session": generation, "shortcutWarning": controls.failedIDs.isEmpty ? "" : language.text("녹음 단축키를 등록하지 못했습니다. 다른 앱의 단축키 또는 손쉬운 사용 권한을 확인하세요.", "A recording shortcut could not be registered. Check other apps’ shortcuts or Accessibility permission.")]
        if let action { value["action"] = action }
        guard let data = try? JSONSerialization.data(withJSONObject: value), let string = String(data: data, encoding: .utf8) else { return }
        string.withCString { callback?($0) }
    }
    func toggle(fallbackPID: Int32, promptMode: Bool = false) {
        if phase == "recording" { stop(paste: promptMode ? true : nil, processAsPrompt: promptMode); return }
        guard !busy else { return }
        clear()
        generation &+= 1
        processingMode = promptMode ? "prompt" : "none"; receipt = UsageReceipt(); refinementWarning = ""
        target = TextInjector.captureTarget(fallbackPID: fallbackPID)
        phase = "preparing"; message = ""
        show(); installCancel(); emit(action: "configure")
    }
    func configure(_ json: String, session: UInt64) {
        guard session == generation, phase == "preparing" else { return }
        do {
            let config = try JSONDecoder().decode(DictationConfiguration.self, from: Data(json.utf8))
            if processingMode != "prompt" { processingMode = (config.enhancementMode == "cleanup" || (config.enhancementMode == nil && (config.refineText ?? false))) ? "cleanup" : "none" }
            configuration = config; language.english = config.uiLanguage == "en"
            overlaySettings = (try? JSONDecoder().decode(OverlaySettings.self, from: Data(json.utf8))) ?? OverlaySettings()
            controls.settings = overlaySettings; installCancel()
            work = Task {
                do {
                    try await recorder.start()
                    try Task.checkCancellation()
                    guard session == generation else { return }
                    phase = "recording"; if presentsOverlay { controls.install(recording: true) }; show(); emit()
                    timer = Task {
                        try? await Task.sleep(for: .seconds(300))
                        guard !Task.isCancelled, session == generation, phase == "recording" else { return }
                        // Never automatically spend money when the recording limit is reached.
                        fail(language.text("5분 녹음 제한에 도달했습니다. 다시 시작해 주세요.", "Recording reached the five-minute limit. Please start again."))
                    }
                } catch {
                    guard !Task.isCancelled, session == generation else { return }
                    fail(error.localizedDescription)
                }
            }
        } catch { fail("받아쓰기 설정을 읽지 못했습니다.") }
    }
    func configurationFailed(_ text: String, session: UInt64) {
        guard generation == session, phase == "preparing" else { return }
        fail(text)
    }
    func stop(pressEnter: Bool = false, paste: Bool? = nil, processAsPrompt: Bool? = nil) {
        guard phase == "recording", let config = configuration else { return }
        if let processAsPrompt, config.enhancementMode == "prompt" {
            processingMode = processAsPrompt ? "prompt" : "none"
        } else if processAsPrompt == true, config.enhancementMode != nil {
            // A stale registered prompt shortcut must not activate a disabled enhancement.
            return
        }
        let shouldPaste = paste ?? (pressEnter || overlaySettings.defaultDelivery != "copy")
        timer?.cancel()
        guard let audio = recorder.stop() else { fail("녹음 파일을 만들지 못했습니다."); return }
        let session = generation
        transcriptionAudio = audio
        if presentsOverlay { controls.install(recording: false) }
        phase = "transcribing"; amplitude = 0; show(); emit()
        work = Task {
            defer {
                try? FileManager.default.removeItem(at: audio)
                if generation == session { transcriptionAudio = nil }
            }
            do {
                let raw: String
                sendInternal(["action":"usage-start", "session":session, "provider":config.provider, "model":config.provider == "local" ? URL(fileURLWithPath: config.modelPath).lastPathComponent : config.model])
                if config.provider == "local" {
                    raw = try await LocalWhisperService().transcribe(audioURL: audio, executableURL: URL(fileURLWithPath: config.whisperPath), modelURL: URL(fileURLWithPath: config.modelPath), language: config.language, prompt: config.effectivePrompt)
                } else {
                    guard let provider = RemoteProvider(rawValue: config.provider) else { throw DictationFailure("지원하지 않는 제공자입니다.") }
                    raw = try await RemoteTranscriptionService(onUsage: { [self] data in
                        self.recordUsage(data, config: config, session: session)
                    }).transcribe(audioURL: audio,
                        configuration: RemoteConfiguration(provider: provider, apiKey: config.apiKey, baseURL: config.baseURL, model: config.model),
                        language: config.language, prompt: config.effectivePrompt, vocabulary: config.vocabulary)
                }
                if config.provider == "local" { recordUsage(Data("{}".utf8), config: config, session: session) }
                try Task.checkCancellation()
                guard generation == session else { return }
                var text = TextPostProcessor.clean(raw, vocabulary: config.vocabulary)
                guard !text.isEmpty, text.utf8.count <= 1_048_576 else { throw DictationFailure(language.text("음성을 인식하지 못했습니다. 다시 말해 주세요.", "No speech was recognized. Please try again.")) }
                originalTranscript = text; lastTranscript = text
                if processingMode != "none" {
                    timer?.cancel()
                    phase = "processing"; show(); emit()
                    timer = Task {
                        try? await Task.sleep(for: .seconds(22))
                        guard !Task.isCancelled, generation == session, phase == "processing" else { return }
                        processed(ProcessingResult(error: "Text processing timed out. Used the original text."), session: session)
                    }
                    let result = await withCheckedContinuation { continuation in
                        processingContinuation = continuation
                        guard let selection = config.processingModel,
                              let data = try? JSONEncoder().encode(selection),
                              let value = try? JSONSerialization.jsonObject(with: data) else {
                            processed(ProcessingResult(error: "Choose a text processing model."), session: session); return
                        }
                        if callback == nil { processed(ProcessingResult(error: "Text processing is unavailable."), session: session); return }
                        sendInternal(["action":"process", "session":session, "processingMode":processingMode, "processingModel":value, "processingPrompt":config.processingPrompt ?? "", "transcript":text])
                    }
                    try Task.checkCancellation()
                    guard generation == session else { return }
                    if let refined = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !refined.isEmpty, refined.utf8.count <= 1_048_576 {
                        text = refined
                    } else {
                        refinementWarning = language.text("다듬지 못해 원문을 사용했습니다.", "Could not refine. Used the original text.")
                    }
                }
                timer?.cancel()
                lastTranscript = text
                phase = "inserting"; emit()
                let result = await deliver(text, shouldPaste, pressEnter, target)
                try Task.checkCancellation()
                guard generation == session else { return }
                timer?.cancel(); configuration = nil; target = nil; removeCancel()
                if result.enteredInTargetApp || (!shouldPaste && result == .copied) {
                    phase = "idle"; message = refinementWarning
                    if presentsOverlay {
                        let summary = [refinementWarning, receipt.label(language)].filter { !$0.isEmpty }.joined(separator: " · ")
                        if summary.isEmpty { overlay.hide() } else { overlay.showToast(summary); dismissLater(after: 2.2, session: session) }
                    }
                    emit()
                } else {
                    phase = result == .copyFailed ? "error" : "success"
                    message = result.fallbackMessage(language)
                    show(); emit(); dismissLater(after: 1.4, session: session)
                }
            } catch {
                guard !Task.isCancelled, generation == session else { return }
                fail(error.localizedDescription)
            }
        }
        timer = Task {
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, generation == session, busy else { return }
            fail(language.text("전사 시간이 초과되었습니다. 다시 시도해 주세요.", "Transcription timed out. Please try again."))
        }
    }
    func cancel() { generation &+= 1; clear(); phase = "idle"; message = ""; emit() }
    private func clear() {
        work?.cancel(); work = nil;
        processingContinuation?.resume(returning: ProcessingResult(error: "cancelled")); processingContinuation = nil; timer?.cancel(); timer = nil
        if let audio = recorder.stop() { try? FileManager.default.removeItem(at: audio) }
        if let transcriptionAudio { try? FileManager.default.removeItem(at: transcriptionAudio) }; transcriptionAudio = nil
        configuration = nil; target = nil; removeCancel(); overlayPreviewPhase = nil; if presentsOverlay { overlay.hide() }
    }
    func fail(_ text: String) {
        clear(); phase = "error"; message = text; show(); emit(); dismissLater(after: 5, session: generation)
    }
    private func dismissLater(after seconds: Double, session: UInt64) {
        timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, generation == session else { return }
            if presentsOverlay { overlay.hide() }
        }
    }
    func preview(_ json: String? = nil) {
        guard !busy else { return }
        clear(); generation &+= 1; phase = "preview"; amplitude = 0.48; message = ""
        if let json, let settings = try? JSONDecoder().decode(OverlaySettings.self, from: Data(json.utf8)) {
            overlaySettings = settings; language.english = settings.uiLanguage == "en"
        }
        let session = generation
        overlayPreviewPhase = "recording"
        show(); emit()
        timer = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, generation == session else { return }
            overlayPreviewPhase = "transcribing"; show()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, generation == session else { return }
            cancel()
        }
    }
    func sendInternal(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let string = String(data: data, encoding: .utf8) else { return }
        string.withCString { callback?($0) }
    }
    func recordUsage(_ data: Data, config: DictationConfiguration, session: UInt64) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Only usage counters/cost metadata are forwarded. Never forward the response text.
        var value: [String: Any] = ["action":"usage-finish", "session":session, "provider":config.provider]
        if let usage = object["usage"] { value["usage"] = usage }
        if let metadata = object["providerMetadata"] as? [String: Any], let gateway = metadata["gateway"] as? [String: Any], let cost = gateway["cost"] {
            value["providerMetadata"] = ["gateway":["cost":cost]]
        }
        sendInternal(value)
    }
    func processed(_ result: ProcessingResult, session: UInt64) {
        guard generation == session, phase == "processing", let continuation = processingContinuation else { return }
        processingContinuation = nil
        if let usage = result.usage { receipt.add(usage) } else if result.error != nil { receipt.unknown += 1 }
        continuation.resume(returning: result)
    }
    func receivedUsage(_ usage: UsageMeasurement, session: UInt64) {
        guard generation == session else { return }; receipt.add(usage)
    }
    func copyOriginal() {
        guard !originalTranscript.isEmpty else { return }
        if !TextInjector.copy(originalTranscript) { fail(language.text("클립보드에 복사하지 못했습니다.", "Could not copy to the clipboard.")) }
    }
    func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        if !TextInjector.copy(lastTranscript) { fail(language.text("클립보드에 복사하지 못했습니다.", "Could not copy to the clipboard.")) }
    }
    private func installCancel() {
        guard presentsOverlay else { return }
        controls.onCancel = { [weak self] in self?.cancel() }
        controls.onCopy = { [weak self] in self?.stop(paste: false, processAsPrompt: false) }
        controls.onPaste = { [weak self] in self?.stop(paste: true, processAsPrompt: false) }
        controls.onSend = { [weak self] in self?.stop(pressEnter: true, paste: true, processAsPrompt: false) }
        controls.install(recording: false)
    }
    private func removeCancel() {
        controls.remove()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    private func show() {
        guard presentsOverlay else { return }
        if message.isEmpty { overlay.show() } else { overlay.showToast(message) }
    }
}

@_cdecl("prism_dictation_preview") func prismDictationPreview(_ json: UnsafePointer<CChar>) {
    let text = String(cString: json)
    MainActor.assumeIsolated { DictationController.shared.preview(text) }
}

@_cdecl("prism_dictation_init") func prismDictationInit(_ callback: @escaping DictationCallback) {
    MainActor.assumeIsolated { DictationController.shared.callback = callback; DictationController.shared.emit() }
}
@_cdecl("prism_dictation_toggle") func prismDictationToggle(_ pid: Int32) { MainActor.assumeIsolated { DictationController.shared.toggle(fallbackPID: pid) } }
@_cdecl("prism_dictation_action") func prismDictationAction(_ action: Int32) {
    MainActor.assumeIsolated {
        let controller = DictationController.shared
        switch action {
        case 0: controller.cancel()
        case 1: controller.preview()
        case 2: controller.copyLast()
        case 4: controller.requestMicrophonePermission()
        case 5: controller.copyOriginal()
        default: controller.refreshPermissions()
        }
    }
}
@_cdecl("prism_dictation_configure") func prismDictationConfigure(_ json: UnsafePointer<CChar>, _ session: UInt64, _ failed: Bool) {
    let text = String(cString: json)
    MainActor.assumeIsolated {
        if failed { DictationController.shared.configurationFailed(text, session: session) }
        else { DictationController.shared.configure(text, session: session) }
    }
}

@_cdecl("prism_dictation_prompt_toggle") func prismDictationPromptToggle(_ pid: Int32) {
    MainActor.assumeIsolated { DictationController.shared.toggle(fallbackPID: pid, promptMode: true) }
}
@_cdecl("prism_dictation_processed") func prismDictationProcessed(_ json: UnsafePointer<CChar>, _ session: UInt64) {
    let result = (try? JSONDecoder().decode(ProcessingResult.self, from: Data(String(cString: json).utf8))) ?? ProcessingResult(error: "Invalid processing response.")
    MainActor.assumeIsolated { DictationController.shared.processed(result, session: session) }
}
@_cdecl("prism_dictation_usage") func prismDictationUsage(_ json: UnsafePointer<CChar>, _ session: UInt64) {
    guard let usage = try? JSONDecoder().decode(UsageMeasurement.self, from: Data(String(cString: json).utf8)) else { return }
    MainActor.assumeIsolated { DictationController.shared.receivedUsage(usage, session: session) }
}
