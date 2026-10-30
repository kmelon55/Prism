import AppKit
import AVFoundation
import Observation
import PrismKit

/// Owns dictation for the app: settings, start shortcuts, the session controller and the settings pane state.
@MainActor
@Observable
final class DictationService {
    enum SaveState: Equatable { case saved, pending, failed(String) }

    private(set) var settings: DictationSettings
    private(set) var loadError: String?
    private(set) var saveState = SaveState.saved
    private(set) var dictationShortcut: StartShortcut?
    private(set) var promptShortcut: StartShortcut?
    /// Double-tap shortcuts that could not be registered, usually for missing Accessibility permission.
    private(set) var unregisteredShortcuts: Set<DoubleModifier> = []
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var keyRevision = 0

    let paths: AppPaths
    let controller: DictationController
    let keys: DictationKeys
    let localModels: LocalModelManager
    let recovery: DictationRecoveryStore
    @ObservationIgnored let monitor: ModifierShortcutMonitor
    @ObservationIgnored private let store: DictationSettingsStore
    @ObservationIgnored private let shortcutsFile: CommandShortcutsFile
    @ObservationIgnored private let ledger: UsageLedger
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var context: (any PrismContext)?

    init(paths: AppPaths, context: (any PrismContext)?, keys: DictationKeys = DictationKeys()) {
        self.paths = paths
        self.context = context
        self.keys = keys
        store = DictationSettingsStore(paths: paths)
        shortcutsFile = CommandShortcutsFile(url: paths.dataDirectory.appending(path: CommandShortcutsFile.fileName))
        ledger = UsageLedger(url: paths.dataDirectory.appending(path: UsageLedger.fileName))
        recovery = DictationRecoveryStore(directory: paths.dataDirectory.appending(path: DictationRecoveryStore.folderName, directoryHint: .isDirectory))
        localModels = LocalModelManager(paths: paths)
        monitor = ModifierShortcutMonitor()
        do {
            settings = try store.load()
        } catch {
            settings = DictationSettings()
            loadError = error.localizedDescription
        }
        let keys = self.keys
        let paths = self.paths
        let ledger = self.ledger
        controller = DictationController(
            recovery: recovery, modifierShortcuts: monitor, ledger: ledger,
            process: { request in await Self.process(request, keys: keys, paths: paths, ledger: ledger) })
        controller.resolve = { [weak self] promptMode in
            guard let self else { throw CancellationError() }
            return try await self.configuration(promptMode: promptMode)
        }
        monitor.onTrigger = { [weak self] modifier in self?.handleDoubleTap(modifier) }
        let loaded = shortcutsFile.load()
        dictationShortcut = loaded.dictation
        promptShortcut = loaded.prompt
    }

    // MARK: Lifecycle

    func start() {
        reloadShortcuts()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: CommandShortcuts.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadShortcuts() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        })
        // Shortcut edits happen in Prism's settings; pick them up when Prism goes to the background.
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadShortcutsIfChanged() }
        })
    }

    private func reloadShortcutsIfChanged() {
        let loaded = shortcutsFile.load()
        guard loaded.dictation != dictationShortcut || loaded.prompt != promptShortcut else { return }
        reloadShortcuts()
    }

    /// Re-reads `command-shortcuts-v1.json` and registers double-tap start shortcuts.
    func reloadShortcuts() {
        let loaded = shortcutsFile.load()
        dictationShortcut = loaded.dictation
        promptShortcut = loaded.prompt
        registerDoubleTaps()
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard trusted != accessibilityTrusted || !unregisteredShortcuts.isEmpty else { return }
        accessibilityTrusted = trusted
        registerDoubleTaps()
        controller.refreshControls()
    }

    private func registerDoubleTaps() {
        monitor.unregisterAll()
        var failed: Set<DoubleModifier> = []
        for shortcut in [dictationShortcut, promptShortcut] {
            guard let modifier = shortcut?.doubleModifier, !monitor.registered.contains(modifier) else { continue }
            do { try monitor.register(modifier) } catch { failed.insert(modifier) }
        }
        unregisteredShortcuts = failed
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func handleDoubleTap(_ modifier: DoubleModifier) {
        // Never act on a binding that was changed or removed since it was registered.
        let loaded = shortcutsFile.load()
        if loaded.dictation != dictationShortcut || loaded.prompt != promptShortcut {
            reloadShortcuts()
            guard loaded.dictation?.doubleModifier == modifier || loaded.prompt?.doubleModifier == modifier else { return }
        }
        // The prompt shortcut wins when both commands share a key; the Tauri app rejects duplicates anyway.
        if promptShortcut?.doubleModifier == modifier {
            toggle(promptMode: true)
        } else if dictationShortcut?.doubleModifier == modifier {
            toggle(promptMode: false)
        }
    }

    // MARK: Sessions

    /// Starts or finishes a session. The frontmost app is the target; `fallbackPID` decides when Prism is frontmost.
    func toggle(promptMode: Bool) {
        let fallback = Self.fallbackPID(paletteVisible: context?.isPaletteVisible ?? false, prismActive: NSApp.isActive,
                                        previousPID: context?.previousApplication?.processIdentifier ?? 0,
                                        ownPID: ProcessInfo.processInfo.processIdentifier)
        controller.toggle(fallbackPID: fallback, promptMode: promptMode)
    }

    /// From the open launcher, the app that was active before it opened; from a shortcut while another Prism
    /// window is in front (AI chat, settings), Prism itself; otherwise none, so the frontmost app is used.
    nonisolated static func fallbackPID(paletteVisible: Bool, prismActive: Bool, previousPID: pid_t, ownPID: pid_t) -> pid_t {
        if paletteVisible { return previousPID }
        return prismActive ? ownPID : 0
    }

    private func configuration(promptMode: Bool) async throws -> DictationConfiguration {
        let settings = try store.load()
        try settings.preflight()
        if promptMode {
            guard settings.mode.includes(.prompt) else {
                throw DictationError(String(localized: "Enable prompt structuring first.", bundle: .module))
            }
            guard settings.promptModel != nil else { throw DictationError(String(localized: "Choose a text processing model.", bundle: .module)) }
        }
        let keys = keys
        let provider = settings.provider
        let apiKey = provider == .local ? "" : try await Task.detached(priority: .userInitiated) { try keys.key(for: provider) }.value
        let primary = promptMode ? promptShortcut : dictationShortcut
        let additional = settings.mode.includes(.prompt) ? [dictationShortcut, promptShortcut] : []
        return DictationConfiguration(settings: settings, apiKey: apiKey,
                                      controls: RecordingControlSettings(settings: settings, primary: primary, additional: additional))
    }

    private nonisolated static func process(_ request: ProcessingRequest, keys: DictationKeys, paths: AppPaths, ledger: UsageLedger) async -> ProcessingResult {
        do {
            let instruction = try ProcessingPrompts.instruction(request.mode, custom: request.instruction)
            let provider = request.selection.provider
            let compatible = provider == .compatible ? CompatibleConnection.load(paths: paths) : nil
            let base = compatible?.normalizedBase
            let apiKey = try keys.key(for: provider, compatibleBase: compatible?.hasKey == true ? base : nil)
            let endpoint = try TextProcessor.endpoint(for: provider, compatibleBase: base, apiKey: apiKey)
            let ticket = ledger.start(feature: request.mode.rawValue, provider: provider.rawValue, model: request.selection.model)
            do {
                let (text, usage) = try await TextProcessor().rewrite(request.transcript, provider: provider, model: request.selection.model,
                                                                      instruction: instruction, endpoint: endpoint)
                if let ticket { ledger.finish(ticket, usage: usage) }
                return ProcessingResult(text: text, usage: usage)
            } catch {
                if let ticket { ledger.finish(ticket, usage: UsageMeasurement(), status: "failed") }
                throw error
            }
        } catch {
            return ProcessingResult(error: error.localizedDescription)
        }
    }

    // MARK: Settings

    /// Applies an edit and saves it after `delay`. Invalid recording keys keep the last saved bindings.
    func update(_ next: DictationSettings, delay: Duration = .zero) {
        settings = next
        saveState = .pending
        saveTask?.cancel()
        saveTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard saveState != .saved else { return true }
        return persist()
    }

    @discardableResult
    private func persist() -> Bool {
        var value = settings
        // Provider tabs can be browsed before a model is chosen; keep the last complete selection on disk.
        let incomplete = value.provider == .local ? value.modelPath.isEmpty || value.whisperPath.isEmpty : value.model.isEmpty
        if incomplete, let saved = try? store.load() {
            value.provider = saved.provider
            value.model = saved.model
            value.baseURL = saved.baseURL
        }
        if RecordingShortcutSetting.validationError(value.recordingBindings) != nil, let saved = try? store.load() {
            for action in RecordingAction.allCases { value.setBinding(saved.binding(action), for: action) }
        }
        do {
            _ = try store.save(value)
            saveState = .saved
            loadError = nil
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            return false
        }
    }

    func keyInfo(for provider: SpeechProvider) -> DictationKeyInfo {
        _ = keyRevision
        return keys.info(for: provider)
    }

    func saveKey(_ key: String, for provider: SpeechProvider) async throws {
        let keys = keys
        _ = try await Task.detached(priority: .userInitiated) { try keys.save(key, for: provider) }.value
        keyRevision += 1
    }

    func deleteKey(for provider: SpeechProvider) async throws {
        let keys = keys
        try await Task.detached(priority: .userInitiated) { try keys.delete(for: provider) }.value
        keyRevision += 1
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func preview() {
        controller.preview(settings: settings, controls: RecordingControlSettings(settings: settings, primary: dictationShortcut))
    }

    func openRecoveryFolder() {
        try? recovery.prepare()
        NSWorkspace.shared.open(recovery.directory)
    }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
