import AppKit
import Observation
import PrismKit

/// One conversation's in-flight reply. Up to three conversations may reply at once.
struct ChatRequestState: Equatable {
    var id: String?
    var pending = ""
    var streamed = ""
    var question = ""
    var error = ""
    var cancelled = false
    var compacting = false

    var isRunning: Bool { id != nil }
}

/// Serializes history writes and deletes on one background queue, like the Tauri renderer's history queue.
final class HistoryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = lock.withLock {
            let previous = tail
            let task = Task.detached { () -> Result<T, any Error> in
                await previous?.value
                return Result { try operation() }
            }
            tail = Task { _ = await task.value }
            return task
        }
        return try await task.value.get()
    }
}

@MainActor
@Observable
final class ChatModel {
    // Conversations
    private(set) var sessions: [ChatSession] = []
    private(set) var current: ChatSession
    var filter = ""
    private(set) var historyReady = false
    private(set) var historyErrors: [String: String] = [:]
    private(set) var requests: [String: ChatRequestState] = [:]
    private(set) var switching = false
    private(set) var capturing = false
    var notice: String?
    var deleteTarget: ChatSession?
    var deleteError: String?
    var visibleMessageCount = 60
    private(set) var failedEntry: (text: String, image: ChatImage?)?

    // Connection
    private(set) var selection: AISelection = .empty
    private(set) var configured = false
    private(set) var checking = false
    private(set) var catalog: (provider: AIProvider, models: [AIModel])?
    private(set) var toolSettings = AIToolSettings()
    var useFiles = false
    private(set) var filesBusy = false
    /// Bumped when the composer should take focus.
    private(set) var focusToken = 0

    @ObservationIgnored let service: AIService
    @ObservationIgnored let store: ChatHistoryStore?
    @ObservationIgnored private let queue = HistoryQueue()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var savedVersions: [String: ChatSession] = [:]
    @ObservationIgnored private var deleting = Set<String>()
    @ObservationIgnored private var mutation = false
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var captureRegion: () async throws -> ChatImage? = { nil }

    init(service: AIService, store: ChatHistoryStore?) {
        self.service = service
        self.store = store
        current = ChatSession(selection: .empty)
        observers.append(NotificationCenter.default.addObserver(forName: .prismAISettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConfiguration() }
        })
    }

    // MARK: Derived state

    var activeRequest: ChatRequestState { requests[current.id] ?? ChatRequestState() }
    var busy: Bool { activeRequest.isRunning }
    var activeCount: Int { requests.values.filter(\.isRunning).count }
    var historyError: String? { historyErrors[current.id] ?? historyErrors["load"] }
    var hasSavedSession: Bool { sessions.contains { $0.id == current.id } }
    var filteredSessions: [ChatSession] { sessions.filter { $0.matches(filter) } }

    var currentModel: AIModel? {
        guard let catalog, catalog.provider == current.provider else { return nil }
        return catalog.models.first { $0.id == current.model }
    }

    var imageUnsupported: Bool { currentModel?.supportsImages == false }
    var hasImages: Bool { current.draftImage != nil || current.messages.contains { $0.image != nil } }

    var readyToSend: Bool {
        !(imageUnsupported && hasImages) && historyReady && configured && !current.model.isEmpty && !checking && !capturing && !switching && deleteTarget == nil
    }

    var canSend: Bool {
        !busy && readyToSend && !filesBusy && activeCount < AIRequestRegistry.limit
            && !current.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isRunning(_ id: String) -> Bool { requests[id]?.isRunning == true }

    /// Messages to show, including the pending question and the streaming answer.
    var displayMessages: [ChatTurn] {
        let request = activeRequest
        guard !request.pending.isEmpty || !request.streamed.isEmpty else { return current.messages }
        var messages = current.messages
        messages.append(ChatTurn(role: "user", content: request.pending.isEmpty ? request.question : request.pending, image: current.draftImage))
        if !request.streamed.isEmpty {
            messages.append(ChatTurn(role: "assistant", content: request.streamed, modelName: current.modelLabel))
        }
        return messages
    }

    // MARK: Loading

    func load() {
        guard !historyReady else { return }
        let store = store, service = service, queue = queue
        Task {
            do {
                async let selection = Task.detached { try service.selection.load() }.value
                async let history = queue.run { try store?.load() ?? [] }
                let (next, loaded) = try await (selection, history)
                self.selection = next ?? .empty
                sessions = ChatSession.sorted(loaded)
                for session in loaded { savedVersions[session.id] = Self.normalized(session) }
                historyReady = true
                historyErrors = [:]
                if let entry = failedEntry {
                    failedEntry = nil
                    await accept(text: entry.text, image: entry.image)
                } else if current.isEmpty {
                    replaceCurrent(sessions.first ?? ChatSession(selection: self.selection))
                }
                refreshConfiguration()
            } catch {
                historyErrors["load"] = Self.message(error)
            }
        }
    }

    func retryHistory() {
        if historyReady {
            Task { await persist(current) }
        } else {
            historyErrors["load"] = nil
            load()
        }
    }

    /// Reloads the default selection, key status, tools and catalog after a settings change or window focus.
    func refreshConfiguration() {
        guard historyReady else { return }
        let service = service
        let provider = current.provider
        let previous = selection
        Task {
            if !isRunning(current.id), let next = try? await Task.detached(operation: { try service.selection.load() }).value {
                selection = next
                // An unfinished empty conversation adopts the updated default.
                if current.messages.isEmpty, current.selection.provider == previous.provider, current.model == previous.model, current.selection != next {
                    replaceCurrent({ var session = current; session.selection = next; return session }())
                }
            }
            if let tools = try? await Task.detached(operation: { try service.tools.load() }).value {
                toolSettings = tools
                if !tools.localFiles || tools.folders.isEmpty { useFiles = false }
            }
        }
        checkKey(provider)
        loadCatalog()
    }

    private func checkKey(_ provider: AIProvider) {
        checking = true
        configured = false
        let service = service
        Task {
            let result = await Task.detached { Result { try service.keyConfigured(provider) } }.value
            guard current.provider == provider else { return }
            switch result {
            case .success(let value): configured = value
            case .failure(let error): setError(Self.message(error))
            }
            checking = false
        }
    }

    private func loadCatalog() {
        let provider = current.provider, service = service
        Task {
            let cached = await service.cache.models(for: provider)
            let models = if let cached { cached } else { (try? await service.listModels(provider)) ?? [] }
            if current.provider == provider { catalog = (provider, models) }
        }
    }

    // MARK: Editing

    func updateDraft(_ text: String) {
        guard current.draft != text else { return }
        current.draft = text
        current.updatedAt = UsageLedger.now
        scheduleAutosave()
    }

    func removeDraftImage() {
        current.draftImage = nil
        current.updatedAt = UsageLedger.now
        scheduleAutosave()
    }

    func applyPreset(_ prompt: String) {
        updateDraft(prompt)
        focusToken += 1
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard historyReady, !busy else { return }
        autosave = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await persist(current)
        }
    }

    private func replaceCurrent(_ session: ChatSession) {
        let changedConversation = session.id != current.id
        current = session
        if changedConversation {
            visibleMessageCount = 60
            focusToken += 1
            loadCatalogIfNeeded()
        }
    }

    private func loadCatalogIfNeeded() {
        if catalog?.provider != current.provider {
            checkKey(current.provider)
            loadCatalog()
        }
    }

    private func remember(_ session: ChatSession) {
        sessions = ChatSession.sorted([session] + sessions.filter { $0.id != session.id })
    }

    private static func normalized(_ session: ChatSession) -> ChatSession {
        var copy = session
        copy.updatedAt = 0
        return copy
    }

    /// Saves a conversation through the history queue. Empty unsaved drafts and deleted conversations are skipped.
    @discardableResult
    func persist(_ session: ChatSession) async -> Bool {
        guard historyReady, let store, !deleting.contains(session.id) else { return true }
        if session.isEmpty && !sessions.contains(where: { $0.id == session.id }) { return true }
        if savedVersions[session.id] == Self.normalized(session) { return true }
        remember(session)
        do {
            let saved = try await queue.run { [deleting] in
                deleting.contains(session.id) ? session : try store.save(session)
            }
            if !deleting.contains(session.id) { savedVersions[session.id] = Self.normalized(saved) }
            historyErrors[session.id] = nil
            return true
        } catch {
            historyErrors[session.id] = Self.message(error)
            return false
        }
    }

    // MARK: Switching

    func newConversation() {
        Task { await switchTo(nil) }
    }

    func select(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        Task { await switchTo(session) }
    }

    /// ⌘1–⌘9 select the visible sidebar rows.
    func selectVisible(_ index: Int) {
        let visible = filteredSessions
        guard visible.indices.contains(index) else { return }
        select(visible[index].id)
    }

    func switchTo(_ session: ChatSession?) async {
        guard !capturing, !mutation, deleteTarget == nil, historyReady, session?.id != current.id else { return }
        mutation = true
        switching = true
        defer { mutation = false; switching = false }
        autosave?.cancel()
        guard await persist(current) else { return }
        replaceCurrent(session.flatMap { target in sessions.first { $0.id == target.id } } ?? ChatSession(selection: selection))
        notice = nil
        if session == nil { filter = "" }
    }

    /// Opens a new unsent draft from the palette query or a capture. The current conversation is saved first.
    func accept(text: String, image: ChatImage?) async {
        guard historyReady else {
            failedEntry = (text, image)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else { return }
        if mutation {
            failedEntry = (text, image)
            return
        }
        mutation = true
        switching = true
        defer { mutation = false; switching = false }
        if await persist(current) {
            replaceCurrent(ChatSession(selection: selection, draft: text, draftImage: image))
            failedEntry = nil
        } else {
            failedEntry = (text, image)
        }
    }

    func retryFailedEntry() {
        guard let entry = failedEntry else { return }
        Task { await accept(text: entry.text, image: entry.image) }
    }

    // MARK: Sending

    func setError(_ message: String, for id: String? = nil) {
        let id = id ?? current.id
        guard !deleting.contains(id) else { return }
        requests[id, default: ChatRequestState()].error = message
    }

    private func patch(_ id: String, _ update: (inout ChatRequestState) -> Void) {
        guard !deleting.contains(id) else { return }
        var state = requests[id] ?? ChatRequestState()
        update(&state)
        requests[id] = state
    }

    func send(_ override: ChatSession? = nil) {
        let source = override ?? current
        guard !isRunning(source.id), !mutation, !source.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              readyToSend, !filesBusy else { return }
        guard activeCount < AIRequestRegistry.limit else {
            setError(L("Up to three conversations can reply at once. Wait for a reply or stop one."))
            return
        }
        var session = source
        if session.hasDefaultTitle {
            session.title = String(session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(70))
        }
        session.updatedAt = UsageLedger.now
        let question = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let turns = session.messages.map(\.message) + [AIMessage(role: "user", content: question, image: session.draftImage)]
        let requestID = UUID().uuidString
        autosave?.cancel()
        requests[session.id] = ChatRequestState(id: requestID, question: question)
        notice = nil
        replaceCurrent(session)
        let useFiles = useFiles
        tasks[session.id] = Task { await run(session: session, turns: turns, question: question, requestID: requestID, useFiles: useFiles) }
    }

    private func owns(_ sessionID: String, _ requestID: String) -> Bool {
        !deleting.contains(sessionID) && requests[sessionID]?.id == requestID
    }

    private func run(session start: ChatSession, turns: [AIMessage], question: String, requestID: String, useFiles: Bool) async {
        var session = start
        let id = session.id
        defer {
            if owns(id, requestID) {
                patch(id) { state in
                    if state.cancelled { state.error = AIError.cancelled.message }
                    state.id = nil
                    state.pending = ""
                    state.compacting = false
                }
            }
            tasks[id] = nil
        }
        do {
            // Save the unanswered question before inference, so a failed request remains an editable draft.
            guard await persist(session), owns(id, requestID) else { return }
            patch(id) { $0.pending = question }
            let prepared = try await service.prepareContext(provider: session.provider, model: session.model, messages: turns,
                                                            compaction: session.compaction) { [weak self] in
                Task { @MainActor in
                    guard let self, self.owns(id, requestID), self.requests[id]?.cancelled == false else { return }
                    self.patch(id) { $0.compacting = true }
                }
            }
            guard owns(id, requestID), requests[id]?.cancelled == false else { return }
            if prepared.compaction != session.compaction {
                session.compaction = prepared.compaction
                if current.id == id { current.compaction = prepared.compaction }
                // The summary checkpoint is committed before the answer request; the archive is never replaced.
                guard await persist(session) else { return }
            }
            guard owns(id, requestID), requests[id]?.cancelled == false else { return }
            patch(id) { $0.compacting = false }
            let content = try await service.chat(provider: session.provider, model: session.model, messages: prepared.messages, useFiles: useFiles) { [weak self] text in
                Task { @MainActor in
                    guard let self, self.owns(id, requestID), self.requests[id]?.cancelled == false else { return }
                    self.patch(id) { $0.streamed = text }
                }
            }
            guard owns(id, requestID) else { return }
            if requests[id]?.cancelled == true { return }
            var completed = session
            completed.draft = ""
            completed.draftImage = nil
            completed.messages = session.messages + [
                ChatTurn(role: "user", content: question, image: session.draftImage),
                ChatTurn(role: "assistant", content: content, modelName: session.modelLabel),
            ]
            completed.updatedAt = UsageLedger.now
            remember(completed)
            if current.id == id {
                // Keep a draft typed into another field meanwhile? The composer is disabled while busy, so replace.
                current = completed
            }
            patch(id) { $0.streamed = ""; $0.question = ""; $0.pending = "" }
            await persist(completed)
        } catch {
            guard owns(id, requestID) else { return }
            let message = error is CancellationError || requests[id]?.cancelled == true ? AIError.cancelled.message : Self.message(error)
            patch(id) { $0.error = message }
        }
    }

    func cancel(_ sessionID: String? = nil) {
        let id = sessionID ?? current.id
        guard let request = requests[id], request.isRunning, !request.pending.isEmpty, !request.cancelled else { return }
        patch(id) { $0.cancelled = true }
        tasks[id]?.cancel()
    }

    func retry() { send() }

    // MARK: Conversation actions

    func changeModel(_ next: AISelection) async throws {
        guard !capturing, !busy, !mutation, deleteTarget == nil else { return }
        mutation = true
        switching = true
        defer { mutation = false; switching = false }
        var session = current
        let previousLabel = current.modelLabel
        session.messages = session.messages.map { message in
            var message = message
            if message.role == "assistant" && (message.modelName ?? "").isEmpty { message.modelName = previousLabel }
            return message
        }
        session.selection = next
        session.updatedAt = UsageLedger.now
        if historyReady, let store, !(session.isEmpty && !hasSavedSession) {
            // Persist the conversation's model before acknowledging it in the composer.
            let snapshot = session
            let saved = try await queue.run { try store.save(snapshot) }
            savedVersions[session.id] = Self.normalized(saved)
            remember(session)
        }
        replaceCurrent(session)
        current = session
        setError("")
        checkKey(next.provider)
        loadCatalog()
    }

    func setPinned(_ pinned: Bool, for id: String? = nil) {
        Task { await changeMetadata(id: id ?? current.id) { $0.pinned = pinned } }
    }

    func rename(_ title: String, for id: String? = nil) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return await changeMetadata(id: id ?? current.id) { $0.title = String(title.prefix(70)) }
    }

    @discardableResult
    private func changeMetadata(id: String, _ update: (inout ChatSession) -> Void) async -> Bool {
        guard !isRunning(id), !mutation, var session = id == current.id ? current : sessions.first(where: { $0.id == id }) else { return false }
        mutation = true
        switching = true
        defer { mutation = false; switching = false }
        update(&session)
        session.updatedAt = UsageLedger.now
        do {
            if let store {
                let snapshot = session
                let saved = try await queue.run { try store.save(snapshot) }
                savedVersions[session.id] = Self.normalized(saved)
            }
            remember(session)
            if current.id == id { current = session }
            historyErrors[id] = nil
            return true
        } catch {
            historyErrors[id] = Self.message(error)
            return false
        }
    }

    func confirmDelete(_ session: ChatSession? = nil) {
        let target = session ?? current
        guard !capturing, !isRunning(target.id), !mutation else { return }
        deleteError = nil
        deleteTarget = target
    }

    func performDelete() async {
        guard !mutation, let target = deleteTarget, !isRunning(target.id) else { return }
        let id = target.id
        mutation = true
        switching = true
        deleteError = nil
        deleting.insert(id)
        defer { mutation = false; switching = false }
        do {
            if let store, ChatSession.isValidID(id) { try await queue.run { try store.delete(id) } }
            let index = sessions.firstIndex { $0.id == id } ?? 0
            sessions.removeAll { $0.id == id }
            savedVersions[id] = nil
            requests[id] = nil
            if current.id == id {
                replaceCurrent(sessions.isEmpty ? ChatSession(selection: selection) : sessions[min(index, sessions.count - 1)])
                historyErrors[id] = nil
                notice = nil
            }
            deleteTarget = nil
        } catch {
            deleting.remove(id)
            deleteError = Self.message(error)
        }
    }

    /// Edit (and regenerate) fork the conversation at a user turn. Source and fork are saved before switching.
    func fork(at index: Int, regenerate: Bool) {
        guard !busy, !mutation, deleteTarget == nil else { return }
        Task {
            mutation = true
            switching = true
            var fork: ChatSession?
            if await persist(current), let created = try? current.fork(at: index), await persist(created) {
                replaceCurrent(created)
                setError("")
                filter = ""
                fork = created
            }
            mutation = false
            switching = false
            if let fork, regenerate { send(fork) }
        }
    }

    func copy(_ text: String, notice message: String = L("Copied")) {
        PasteService.copy(text)
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if notice == message { notice = nil }
        }
    }

    // MARK: Images and files

    private func canAttachImage() -> Bool {
        guard !capturing, !busy, !mutation, historyReady, deleteTarget == nil else { return false }
        if imageUnsupported {
            setError(L("This model does not support images. Choose an image-capable model."))
            return false
        }
        if current.messages.filter({ $0.image != nil }).count >= ChatImageCodec.maxSessionImages {
            setError(L("This conversation already has four images. Start a new conversation to add more."))
            return false
        }
        return true
    }

    func attachImage(from urls: [URL]) {
        guard canAttachImage() else { return }
        guard urls.count == 1, let url = urls.first else {
            setError(L("Drop one image at a time."))
            return
        }
        attach { try ChatImageCodec.encode(fileAt: url) }
    }

    func attachImage(data: Data) {
        guard canAttachImage() else { return }
        attach { try ChatImageCodec.encode(data: data) }
    }

    private func attach(_ encode: @escaping @Sendable () throws -> ChatImage) {
        let id = current.id
        capturing = true
        setError("")
        Task {
            defer { capturing = false; focusToken += 1 }
            do {
                let image = try await Task.detached(operation: encode).value
                guard current.id == id else { return }
                current.draftImage = image
                current.updatedAt = UsageLedger.now
                await persist(current)
            } catch {
                if current.id == id { setError(Self.message(error)) }
            }
        }
    }

    func captureScreenRegion() {
        guard canAttachImage() else { return }
        let id = current.id
        capturing = true
        setError("")
        Task {
            defer { capturing = false; focusToken += 1 }
            do {
                if let image = try await captureRegion(), current.id == id {
                    current.draftImage = image
                    current.updatedAt = UsageLedger.now
                    scheduleAutosave()
                }
            } catch {
                setError(Self.message(error))
            }
        }
    }

    /// The Files control: refreshes permissions and opens a folder chooser when no folder is granted yet.
    func toggleFiles(chooseFolder: @escaping @MainActor () -> URL?) {
        guard !busy, !filesBusy else { return }
        if useFiles {
            useFiles = false
            return
        }
        filesBusy = true
        setError("")
        let tools = service.tools
        Task {
            defer { filesBusy = false }
            do {
                var next = try tools.load()
                if next.folders.isEmpty {
                    guard let url = chooseFolder() else { return }
                    next = try tools.addFolder(url)
                } else if !next.localFiles {
                    next = try tools.set(localFiles: true, maxOutputTokens: next.maxOutputTokens)
                }
                toolSettings = next
                useFiles = next.localFiles && !next.folders.isEmpty
                NotificationCenter.default.post(name: .prismAISettingsChanged, object: nil)
            } catch {
                setError(Self.message(error))
            }
        }
    }

    // MARK: Export

    func exportMarkdown(_ session: ChatSession? = nil) -> (name: String, text: String) {
        let session = session ?? current
        return (session.exportFileName, session.markdown())
    }

    /// Saves the current conversation and stops every reply, as when the window closes for good.
    func saveOnClose() {
        autosave?.cancel()
        Task { await persist(current) }
    }

    static func message(_ error: any Error) -> String {
        (error as? AIError)?.message ?? L("Could not complete the action. Try again.")
    }
}
