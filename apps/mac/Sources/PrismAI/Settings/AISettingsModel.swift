import AppKit
import Observation
import PrismKit

/// State and actions for Settings › AI. Keys are only ever written here; nothing reads a key back for display
/// beyond its masked suffix.
@MainActor
@Observable
final class AISettingsModel {
    let service: AIService
    private(set) var saved: AISelection = .empty
    private(set) var ready = false
    var provider: AIProvider = .vercel
    private(set) var keyInfo: AIKeyInfo?
    private(set) var checking = false
    var keyText = ""
    var editingKey = false
    private(set) var busy = false
    private(set) var keyError: String?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var activeModel: AIModel?

    // Custom server
    private(set) var connection = CompatibleConnection()
    var baseURLText = ""
    var compatibleKeyText = ""
    var compatibleModelText = ""

    // Tools
    private(set) var tools = AIToolSettings()
    private(set) var toolsReady = false
    private(set) var toolsError: String?

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(service: AIService) {
        self.service = service
        observer = NotificationCenter.default.addObserver(forName: .prismAISettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }
                self.reloadSelection()
                self.reloadTools()
                self.checkKey()
            }
        }
    }

    func load() {
        reloadSelection(initial: true)
        reloadTools()
        reloadCompatible()
    }

    private func reloadSelection(initial: Bool = false) {
        let service = service
        Task {
            do {
                let selection = try await Task.detached { try service.selection.load() }.value ?? .empty
                saved = selection
                if initial {
                    provider = selection.provider
                    ready = true
                    checkKey()
                }
                await refreshActiveModel()
            } catch {
                self.error = ChatModel.message(error)
                ready = true
            }
        }
    }

    private func refreshActiveModel() async {
        let service = service, saved = saved
        guard !saved.model.isEmpty else { activeModel = nil; return }
        var models = await service.cache.models(for: saved.provider)
        if models == nil, saved.provider != .openai { models = try? await service.listModels(saved.provider) }
        activeModel = models?.first { $0.id == saved.model }
    }

    private func reloadTools() {
        let service = service
        Task {
            do {
                tools = try await Task.detached { try service.tools.load() }.value
                toolsReady = true
            } catch {
                toolsError = ChatModel.message(error)
            }
        }
    }

    private func reloadCompatible() {
        let service = service
        Task {
            do {
                connection = try await Task.detached { try service.compatible.load() }.value
                baseURLText = connection.baseUrl
            } catch {
                keyError = ChatModel.message(error)
            }
        }
    }

    func changeProvider(_ next: AIProvider) {
        guard next != provider || keyInfo == nil, !busy else { return }
        provider = next
        keyInfo = nil
        keyText = ""
        editingKey = false
        keyError = nil
        notice = nil
        error = nil
        checkKey()
    }

    func checkKey() {
        guard provider != .compatible else { checking = false; return }
        let provider = provider, keys = service.keys
        checking = true
        keyError = nil
        Task {
            let result = await Task.detached { Result { try keys.info(provider) } }.value
            guard self.provider == provider else { return }
            checking = false
            switch result {
            case .success(let info): keyInfo = info
            case .failure(let error): keyError = ChatModel.message(error)
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .prismAISettingsChanged, object: nil)
    }

    private func perform(_ work: @escaping @Sendable () throws -> AIKeyInfo?, success: @escaping (AIKeyInfo?) -> Void) {
        guard !busy else { return }
        busy = true
        keyError = nil
        notice = nil
        let destination = provider
        Task {
            let result = await Task.detached { Result { try work() } }.value
            busy = false
            guard provider == destination else { return }
            switch result {
            case .success(let info): success(info)
            case .failure(let error): keyError = ChatModel.message(error)
            }
            notify()
        }
    }

    func saveKey() {
        let key = keyText, provider = provider, keys = service.keys
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform({ try keys.save(provider, key: key) }) { [weak self] info in
            guard let self else { return }
            keyInfo = info
            keyText = ""
            editingKey = false
            notice = L("API key saved in Keychain. You can use it in this app right away.")
        }
    }

    func deleteKey() {
        let provider = provider, keys = service.keys
        perform({ try keys.delete(provider); return try keys.info(provider) }) { [weak self] info in
            guard let self else { return }
            if info?.configured == true {
                keyError = L("Could not confirm the key was deleted. Try again.")
                return
            }
            keyInfo = info
            notice = L("API key deleted.")
        }
    }

    func unlockKey() {
        let provider = provider, keys = service.keys
        perform({ try keys.unlock(provider) }) { [weak self] info in
            guard let self else { return }
            guard let info, info.configured, info.unlocked else {
                keyError = L("The saved key cannot be used. Save the API key again.")
                return
            }
            keyInfo = info
            notice = L("Prism reuses the approved key while it is running.")
        }
    }

    func select(_ selection: AISelection) async throws {
        let store = service.selection
        let result = try await Task.detached { try store.save(selection) }.value
        saved = result
        let configured = selection.provider == .compatible || (provider == selection.provider && keyInfo?.configured == true)
        notice = L("Saved \(selection.displayName).") + " " + (configured ? L("You can use it in AI Chat.") : L("Save an API key to use it."))
        notify()
        await refreshActiveModel()
    }

    // MARK: Custom server

    var compatibleChanged: Bool {
        baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).trimmingSuffix("/") != connection.baseUrl.trimmingSuffix("/")
    }

    func saveConnection() {
        guard !busy else { return }
        let store = service.compatible, keys = service.keys
        let base = baseURLText, key = compatibleKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        keyError = nil
        notice = nil
        Task {
            let result = await Task.detached { Result { try store.save(baseUrl: base, key: key.isEmpty ? nil : key, keys: keys) } }.value
            busy = false
            switch result {
            case .success(let value):
                connection = value
                baseURLText = value.baseUrl
                compatibleKeyText = ""
                notice = L("Connection saved. Choose a model or enter its ID below.")
                notify()
            case .failure(let error):
                keyError = ChatModel.message(error)
            }
        }
    }

    func unlockCompatible() {
        guard !busy else { return }
        let service = service
        busy = true
        keyError = nil
        Task {
            let result = await Task.detached { Result { _ = try service.compatibleTarget("models", allowPrompt: true) } }.value
            busy = false
            switch result {
            case .success: notice = L("Prism reuses the approved key while it is running.")
            case .failure(let error): keyError = ChatModel.message(error)
            }
        }
    }

    func useCompatibleModel() {
        let id = compatibleModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !compatibleChanged, !connection.baseUrl.isEmpty else { return }
        Task {
            do {
                try await select(AISelection(provider: .compatible, model: id, modelName: id))
                compatibleModelText = ""
            } catch {
                self.error = ChatModel.message(error)
            }
        }
    }

    // MARK: Tools

    private func updateTools(_ work: @escaping @Sendable () throws -> AIToolSettings) {
        guard !busy else { return }
        busy = true
        toolsError = nil
        Task {
            let result = await Task.detached { Result { try work() } }.value
            busy = false
            switch result {
            case .success(let value):
                tools = value
                notify()
            case .failure(let error):
                toolsError = ChatModel.message(error)
            }
        }
    }

    func setLocalFiles(_ enabled: Bool) {
        let store = service.tools, current = tools
        if enabled && current.folders.isEmpty {
            guard let url = ChatWindowController.chooseFolder() else { return }
            updateTools { try store.addFolder(url) }
        } else {
            updateTools { try store.set(localFiles: enabled, maxOutputTokens: current.maxOutputTokens) }
        }
    }

    func addFolder() {
        guard let url = ChatWindowController.chooseFolder() else { return }
        let store = service.tools
        updateTools { try store.addFolder(url) }
    }

    func removeFolder(_ id: String) {
        let store = service.tools
        updateTools { try store.removeFolder(id) }
    }

    func setOutputLimit(_ limit: Int) {
        let store = service.tools, enabled = tools.localFiles
        updateTools { try store.set(localFiles: enabled, maxOutputTokens: limit) }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
