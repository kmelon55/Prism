// Whisp recording, waveform and text delivery adapted for Prism. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit
import Observation

enum DictationPhase: String, Sendable {
    case idle, preparing, recording, transcribing, processing, inserting, error, preview

    var isBusy: Bool { [.preparing, .recording, .transcribing, .processing, .inserting].contains(self) }
}

/// Everything one recording session needs, resolved when it starts. The key never leaves memory.
struct DictationConfiguration: Sendable {
    var settings: DictationSettings
    var apiKey: String = ""
    var controls = RecordingControlSettings()
}

/// One enhancement request handed to the text processor.
struct ProcessingRequest: Sendable {
    let mode: ProcessingMode
    let selection: ProcessingSelection
    let instruction: String
    let transcript: String
}

struct RecordingOverlayHint: Identifiable, Equatable {
    let id: String
    let key: String
    let label: String
}

/// The dictation session: record, transcribe, optionally refine, then copy or paste into the captured app.
/// A generation number guards every await so cancelled or stale sessions can never deliver text.
@MainActor
@Observable
final class DictationController {
    typealias Deliver = @MainActor (_ text: String, _ paste: Bool, _ enter: Bool, _ target: TextInsertionTarget?, _ saveToHistory: Bool) async -> TextDeliveryResult
    typealias Resolve = @MainActor (_ promptMode: Bool) async throws -> DictationConfiguration
    typealias Process = @Sendable (ProcessingRequest) async -> ProcessingResult

    private(set) var phase = DictationPhase.idle
    private(set) var amplitude = 0.0
    private(set) var message = ""
    private(set) var processingMode: ProcessingMode?
    private(set) var previewPhase: DictationPhase?
    private(set) var overlayVisible = false
    private(set) var recoveryWarning = ""
    private(set) var lastTranscript = ""
    private(set) var originalTranscript = ""
    private(set) var showRecordingShortcutHints = true
    private(set) var showTranscriptionStatus = true
    /// Bumped whenever registration of the recording keys changes, so the overlay hints refresh.
    private(set) var controlsRevision = 0

    var busy: Bool { phase.isBusy }
    var displayedPhase: DictationPhase { previewPhase ?? phase }
    var shortcutWarning: Bool { !controls.failedActions.isEmpty }

    @ObservationIgnored private let recorder: any DictationRecording
    @ObservationIgnored private let presentsOverlay: Bool
    @ObservationIgnored private let toastDuration: Double
    @ObservationIgnored private let recovery: DictationRecoveryStore?
    @ObservationIgnored private let deliver: Deliver
    /// Loads settings and keys when a session starts. Tests leave it nil and call `configure` directly.
    @ObservationIgnored var resolve: Resolve?
    @ObservationIgnored private let process: Process?
    @ObservationIgnored private let ledger: UsageLedger?
    @ObservationIgnored private let controls: RecordingControls
    @ObservationIgnored private lazy var overlay = OverlayPresenter(controller: self)
    @ObservationIgnored private var target: TextInsertionTarget?
    @ObservationIgnored private var transcriptionAudio: URL?
    @ObservationIgnored private var recoveryEntry: URL?
    @ObservationIgnored private var configuration: DictationConfiguration?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var processingContinuation: CheckedContinuation<ProcessingResult, Never>?
    @ObservationIgnored private(set) var generation: UInt64 = 0
    @ObservationIgnored private var promptRequested = false

    init(recorder: (any DictationRecording)? = nil, presentsOverlay: Bool = true, toastDuration: Double = 3,
         recovery: DictationRecoveryStore? = nil, modifierShortcuts: ModifierShortcutMonitor? = nil, ledger: UsageLedger? = nil,
         resolve: Resolve? = nil, process: Process? = nil,
         deliver: @escaping Deliver = { text, paste, enter, target, history in
             await TextInjector.deliver(text, paste: paste, pressEnterAfterPaste: enter, target: target,
                                        copyText: { TextInjector.copy($0, saveToHistory: history) })
         }) {
        let recorder = recorder ?? AudioRecorder()
        self.recorder = recorder
        self.presentsOverlay = presentsOverlay
        self.toastDuration = toastDuration
        self.recovery = recovery
        self.ledger = ledger
        self.resolve = resolve
        self.process = process
        self.deliver = deliver
        controls = RecordingControls(modifierShortcuts: modifierShortcuts)
        if let saved = recovery?.latest() {
            lastTranscript = saved.result
            originalTranscript = saved.original
        }
        recorder.onLevel = { [weak self] level in self?.amplitude = level }
        recorder.onFailure = { [weak self] message in self?.fail(message) }
        controls.onAction = { [weak self] action in self?.perform(action) }
    }

    /// The keys shown beside the waveform, in Whisp's order.
    var recordingHints: [RecordingOverlayHint] {
        _ = controlsRevision
        let settings = controls.settings
        return RecordingAction.hintOrder.compactMap { action in
            let binding = settings.binding(action)
            guard controls.isRegistered(action) || previewPhase != nil || (action == .paste && binding.mode == .sameAsPrimary),
                  let key = settings.label(action) else { return nil }
            let label = action == .paste && binding.mode == .sameAsPrimary && settings.defaultDelivery == .copy ? RecordingAction.copy.hint : action.hint
            return RecordingOverlayHint(id: "\(action.number)", key: key, label: label)
        }
    }

    // MARK: Session

    /// Starts a recording, or finishes the current one. `fallbackPID` is the target when Prism itself is frontmost.
    func toggle(fallbackPID: pid_t, promptMode: Bool = false) {
        if phase == .recording {
            stop(paste: promptMode ? true : nil, processAsPrompt: promptMode)
            return
        }
        guard !busy else { return }
        clear()
        generation &+= 1
        recoveryEntry = nil
        recoveryWarning = ""
        promptRequested = promptMode
        processingMode = promptMode ? .prompt : nil
        target = TextInjector.captureTarget(fallbackPID: fallbackPID)
        phase = .preparing
        message = ""
        show()
        installControls(recording: false)
        guard let resolve else { return }
        let session = generation
        work = Task {
            do {
                let configuration = try await resolve(promptMode)
                configure(configuration, session: session)
            } catch {
                configurationFailed(error.localizedDescription, session: session)
            }
        }
    }

    func configure(_ configuration: DictationConfiguration, session: UInt64) {
        guard session == generation, phase == .preparing else { return }
        let settings = configuration.settings
        if !promptRequested { processingMode = settings.mode.includes(.cleanup) ? .cleanup : nil }
        self.configuration = configuration
        showRecordingShortcutHints = settings.showRecordingShortcutHints
        showTranscriptionStatus = settings.showTranscriptionStatus
        controls.settings = configuration.controls
        installControls(recording: false)
        work = Task {
            do {
                try await recorder.start()
                try Task.checkCancellation()
                guard session == generation else { return }
                phase = .recording
                installControls(recording: true)
                show()
                timer = Task {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, session == generation, phase == .recording else { return }
                    // Never spend money automatically when the recording limit is reached.
                    fail(String(localized: "Recording reached the five-minute limit. Please start again.", bundle: .module))
                }
            } catch {
                guard !Task.isCancelled, session == generation else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func configurationFailed(_ text: String, session: UInt64) {
        guard generation == session, phase == .preparing else { return }
        fail(text)
    }

    /// Finishes the recording. `paste` overrides the default delivery; `processAsPrompt` picks the enhancement.
    func stop(pressEnter: Bool = false, paste: Bool? = nil, processAsPrompt: Bool? = nil) {
        guard phase == .recording, let configuration else { return }
        let settings = configuration.settings
        if let processAsPrompt, settings.mode.includes(.prompt) {
            processingMode = processAsPrompt ? .prompt : (settings.mode.includes(.cleanup) ? .cleanup : nil)
        } else if processAsPrompt == true {
            // A stale prompt shortcut must not activate a disabled enhancement.
            return
        }
        let shouldPaste = paste ?? (pressEnter || settings.defaultDelivery != .copy)
        timer?.cancel()
        guard let audio = recorder.stop() else {
            fail(String(localized: "Could not create the recording file.", bundle: .module))
            return
        }
        let session = generation
        transcriptionAudio = audio
        do { recoveryEntry = try recovery?.preserve(audio) } catch {
            // Keep the source when the recovery folder is unavailable.
            transcriptionAudio = nil
            fail(String(localized: "Could not back up the recording. Original location: ", bundle: .module) + audio.path)
            return
        }
        installControls(recording: false)
        phase = .transcribing
        amplitude = 0
        show()
        work = Task {
            defer {
                try? FileManager.default.removeItem(at: audio)
                if generation == session { transcriptionAudio = nil }
            }
            do {
                let raw = try await transcribe(audio, configuration: configuration)
                try Task.checkCancellation()
                guard generation == session else { return }
                var text = TextPostProcessor.clean(raw, vocabulary: settings.vocabulary)
                guard !text.isEmpty, text.utf8.count <= 1_048_576 else {
                    throw DictationError(String(localized: "No speech was recognized. Please try again.", bundle: .module))
                }
                originalTranscript = text
                lastTranscript = text
                if let recovery, let entry = recoveryEntry { try recovery.save(text, named: "original.txt", in: entry) }
                if let mode = processingMode {
                    timer?.cancel()
                    phase = .processing
                    show()
                    let result = await runProcessing(mode, text: text, settings: settings, session: session)
                    try Task.checkCancellation()
                    guard generation == session else { return }
                    if let refined = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !refined.isEmpty, refined.utf8.count <= 1_048_576 {
                        text = refined
                    }
                    // A failed refinement delivers the saved original without a notice.
                }
                timer?.cancel()
                lastTranscript = text
                if let recovery, let entry = recoveryEntry {
                    try recovery.save(text, named: "result.txt", in: entry)
                    try recovery.finish(entry)
                }
                // Hide before delivery; the live overlay would otherwise fall back to its idle waveform.
                hideOverlay()
                phase = .inserting
                let result = await deliver(text, shouldPaste, pressEnter, target, settings.saveToClipboardHistory)
                try Task.checkCancellation()
                guard generation == session else { return }
                timer?.cancel()
                self.configuration = nil
                target = nil
                removeControls()
                if result.enteredInTargetApp || result == .pasteSent || (!shouldPaste && result == .copied) {
                    phase = .idle
                    message = ""
                    hideOverlay()
                } else {
                    phase = .error
                    message = result.fallbackMessage
                    show()
                    dismissLater(after: toastDuration, session: session)
                }
            } catch {
                guard !Task.isCancelled, generation == session else { return }
                fail(error.localizedDescription)
            }
        }
        timer = Task {
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, generation == session, busy else { return }
            fail(String(localized: "Transcription timed out. Please try again.", bundle: .module))
        }
    }

    func cancel() {
        generation &+= 1
        clear()
        phase = .idle
        message = ""
    }

    /// Stops with an error. Interrupted or over-limit recordings keep their audio in the recovery folder.
    func fail(_ text: String) {
        if let audio = recorder.stop() {
            do {
                if let recovery {
                    recoveryEntry = try recovery.preserve(audio)
                    try? FileManager.default.removeItem(at: audio)
                }
            } catch {
                recoveryWarning = String(localized: "Recording location: ", bundle: .module) + audio.path
            }
        }
        clear()
        phase = .error
        message = text
        show()
        dismissLater(after: toastDuration, session: generation)
    }

    /// Resumes a waiting enhancement. Late results from another session are ignored.
    func processed(_ result: ProcessingResult, session: UInt64) {
        guard generation == session, phase == .processing, let continuation = processingContinuation else { return }
        processingContinuation = nil
        continuation.resume(returning: result)
    }

    /// Plays the recording and transcribing overlay without touching the microphone.
    func preview(settings: DictationSettings, controls previewControls: RecordingControlSettings) {
        guard !busy else { return }
        clear()
        generation &+= 1
        phase = .preview
        amplitude = 0.48
        message = ""
        showRecordingShortcutHints = settings.showRecordingShortcutHints
        showTranscriptionStatus = settings.showTranscriptionStatus
        controls.settings = previewControls
        processingMode = settings.mode.includes(.cleanup) ? .cleanup : nil
        let session = generation
        previewPhase = .recording
        show()
        timer = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, generation == session else { return }
            previewPhase = .transcribing
            show()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, generation == session else { return }
            cancel()
        }
    }

    /// Updates a visible preview with changed overlay switches.
    func updatePreview(settings: DictationSettings) {
        guard phase == .preview else { return }
        showRecordingShortcutHints = settings.showRecordingShortcutHints
        showTranscriptionStatus = settings.showTranscriptionStatus
        show()
    }

    @discardableResult
    func copyOriginal(saveToHistory: Bool = true) -> Bool {
        guard !originalTranscript.isEmpty else { return false }
        return TextInjector.copy(originalTranscript, saveToHistory: saveToHistory)
    }

    @discardableResult
    func copyLast(saveToHistory: Bool = true) -> Bool {
        guard !lastTranscript.isEmpty else { return false }
        return TextInjector.copy(lastTranscript, saveToHistory: saveToHistory)
    }

    /// Re-registers recording keys after Accessibility changes during a session.
    func refreshControls() {
        guard presentsOverlay, busy else { return }
        installControls(recording: phase == .recording)
    }

    // MARK: Private

    private func perform(_ action: RecordingAction) {
        switch action {
        case .cancel: cancel()
        case .copy: stop(paste: false, processAsPrompt: false)
        case .paste: stop(paste: true, processAsPrompt: false)
        case .send: stop(pressEnter: true, paste: true, processAsPrompt: false)
        }
    }

    private func transcribe(_ audio: URL, configuration: DictationConfiguration) async throws -> String {
        let settings = configuration.settings
        let model = settings.provider == .local ? URL(filePath: settings.modelPath).lastPathComponent : settings.model
        let ledger = ledger
        let ticket = await Self.detached { ledger?.start(feature: "transcription", provider: settings.provider.rawValue, model: model) }
        let result: TranscriptionResult
        if settings.provider == .local {
            let text = try await LocalWhisperService().transcribe(audioURL: audio, executableURL: URL(filePath: settings.whisperPath),
                                                                  modelURL: URL(filePath: settings.modelPath), language: settings.language,
                                                                  prompt: settings.effectivePrompt)
            result = TranscriptionResult(text: text, usage: .local)
        } else {
            let remote = RemoteConfiguration(provider: settings.provider, apiKey: configuration.apiKey, baseURL: settings.baseURL, model: settings.model)
            result = try await RemoteTranscriptionService().transcribe(audioURL: audio, configuration: remote, language: settings.language,
                                                                       prompt: settings.effectivePrompt, vocabulary: settings.vocabulary)
        }
        if let ticket { await Self.detached { ledger?.finish(ticket, usage: result.usage) } }
        return result.text
    }

    private func runProcessing(_ mode: ProcessingMode, text: String, settings: DictationSettings, session: UInt64) async -> ProcessingResult {
        timer = Task {
            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled, generation == session, phase == .processing else { return }
            processed(ProcessingResult(error: String(localized: "Text processing timed out. Used the original text.", bundle: .module)), session: session)
        }
        return await withCheckedContinuation { continuation in
            processingContinuation = continuation
            guard let selection = settings.selection(for: mode), selection.isValid else {
                processed(ProcessingResult(error: String(localized: "Choose a text processing model.", bundle: .module)), session: session)
                return
            }
            guard let process else {
                processed(ProcessingResult(error: String(localized: "Text processing is unavailable.", bundle: .module)), session: session)
                return
            }
            let request = ProcessingRequest(mode: mode, selection: selection, instruction: settings.instruction(for: mode), transcript: text)
            processingTask = Task { [weak self] in
                let result = await process(request)
                self?.processed(result, session: session)
            }
        }
    }

    private func clear() {
        work?.cancel()
        work = nil
        processingTask?.cancel()
        processingTask = nil
        processingContinuation?.resume(returning: ProcessingResult(error: "cancelled"))
        processingContinuation = nil
        timer?.cancel()
        timer = nil
        if let audio = recorder.stop() { try? FileManager.default.removeItem(at: audio) }
        if let transcriptionAudio { try? FileManager.default.removeItem(at: transcriptionAudio) }
        transcriptionAudio = nil
        configuration = nil
        target = nil
        removeControls()
        previewPhase = nil
        hideOverlay()
    }

    private func dismissLater(after seconds: Double, session: UInt64) {
        timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, generation == session else { return }
            hideOverlay()
        }
    }

    private func installControls(recording: Bool) {
        guard presentsOverlay else { return }
        controls.install(recording: recording)
        controlsRevision &+= 1
    }

    private func removeControls() {
        controls.remove()
        controlsRevision &+= 1
    }

    private func hideOverlay() {
        overlayVisible = false
        if presentsOverlay { overlay.hide() }
    }

    private func show() {
        guard phase != .inserting else { return }
        overlayVisible = true
        guard presentsOverlay else { return }
        if message.isEmpty { overlay.show() } else { overlay.showToast(message) }
    }

    private nonisolated static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility, operation: work).value
    }
}
