import Foundation
import PrismKit

public struct ChatTurn: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    /// The model that wrote an assistant answer, kept when the conversation switches models.
    public var modelName: String?
    public var image: ChatImage?

    public init(role: String, content: String, modelName: String? = nil, image: ChatImage? = nil) {
        self.role = role
        self.content = content
        self.modelName = modelName
        self.image = image
    }

    var message: AIMessage { AIMessage(role: role, content: content, image: image) }
}

/// One conversation as stored in `ai-conversations.sqlite3` (`conversations.content` JSON), shared with the Tauri app.
public struct ChatSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: AIProvider
    public var model: String
    public var modelName: String?
    public var title: String
    public var messages: [ChatTurn]
    public var compaction: ChatCompaction?
    public var draft: String
    public var draftImage: ChatImage?
    public var updatedAt: Int64
    public var pinned: Bool

    enum CodingKeys: String, CodingKey {
        case id, provider, model, modelName, title, messages, compaction, draft, draftImage, updatedAt, pinned
    }

    public init(id: String = ChatSession.newID(), selection: AISelection, title: String = ChatSession.defaultTitle, messages: [ChatTurn] = [],
                compaction: ChatCompaction? = nil, draft: String = "", draftImage: ChatImage? = nil,
                updatedAt: Int64 = UsageLedger.now, pinned: Bool = false) {
        self.id = id
        provider = selection.provider
        model = selection.model
        modelName = selection.modelName
        self.title = title
        self.messages = messages
        self.compaction = compaction
        self.draft = draft
        self.draftImage = draftImage
        self.updatedAt = updatedAt
        self.pinned = pinned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatTurn].self, forKey: .messages)
        compaction = try container.decodeIfPresent(ChatCompaction.self, forKey: .compaction)
        draft = try container.decode(String.self, forKey: .draft)
        draftImage = try container.decodeIfPresent(ChatImage.self, forKey: .draftImage)
        updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(modelName, forKey: .modelName)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(compaction, forKey: .compaction)
        try container.encode(draft, forKey: .draft)
        try container.encodeIfPresent(draftImage, forKey: .draftImage)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(pinned, forKey: .pinned)
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }
    public static var defaultTitle: String { L("New conversation") }
    static let defaultTitles: Set<String> = ["새 대화", "New conversation"]

    public var selection: AISelection {
        get { AISelection(provider: provider, model: model, modelName: modelName) }
        set {
            provider = newValue.provider
            model = newValue.model
            modelName = newValue.modelName
        }
    }

    public var modelLabel: String { modelName.flatMap { $0.isEmpty ? nil : $0 } ?? model }
    public var hasDefaultTitle: Bool { Self.defaultTitles.contains(title) }
    public var isEmpty: Bool { messages.isEmpty && draft.isEmpty && draftImage == nil }

    /// Sidebar title: an untitled thread shows its draft.
    public var displayTitle: String {
        if hasDefaultTitle, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(45))
        }
        return hasDefaultTitle ? Self.defaultTitle : title
    }

    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 36 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x2D }
    }

    func validate() throws {
        let invalid = !Self.isValidID(id) || title.utf8.count > 300 || model.utf8.count > 200 || !model.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E })
            || (modelName?.utf8.count ?? 0) > 720 || draft.utf8.count > 128_000 || messages.count % 2 != 0
            || messages.enumerated().contains { index, message in
                (message.modelName?.utf8.count ?? 0) > 720 || message.role != (index % 2 == 0 ? "user" : "assistant")
                    || message.content.isEmpty || message.content.utf8.count > 1_048_576
            }
            || messages.reduce(0, { $0 + $1.content.utf8.count }) > AIContext.maxArchiveBytes
        if invalid { throw AIError(L("Conversation history is invalid or too large.")) }
        try compaction?.validate(messageCount: messages.count)
        if messages.contains(where: { $0.role != "user" && $0.image != nil }) {
            throw AIError(L("Conversation images must belong to user messages."))
        }
        for image in messages.compactMap(\.image) + [draftImage].compactMap({ $0 }) { try ChatImageCodec.validate(image) }
    }

    /// Edit and regenerate fork at a user turn, preserving the original and later messages in the source.
    func fork(at userIndex: Int) throws -> ChatSession {
        guard messages.indices.contains(userIndex), messages[userIndex].role == "user" else {
            throw AIError(L("Choose a user message to edit."))
        }
        var fork = self
        fork.id = Self.newID()
        fork.title = "\(String(title.prefix(58))) · \(L("Rewrite"))"
        fork.pinned = false
        fork.messages = Array(messages[..<userIndex])
        if let compaction, compaction.through > userIndex { fork.compaction = nil }
        fork.draft = messages[userIndex].content
        fork.draftImage = messages[userIndex].image
        fork.updatedAt = UsageLedger.now
        return fork
    }

    /// Markdown export with messages and an unsent draft. Never includes credentials.
    func markdown() -> String {
        var text = "# \(title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))\n\n"
        for message in messages {
            if let image = message.image { text += "![Screen capture](\(image.dataUrl))\n\n" }
            let heading = message.role == "user" ? L("You") : (message.modelName ?? model)
            text += "## \(heading)\n\n\(message.content)\n\n"
        }
        if let draftImage { text += "![Draft screen capture](\(draftImage.dataUrl))\n\n" }
        if !draft.isEmpty { text += "## \(L("Draft"))\n\n\(draft)\n" }
        return text
    }

    var exportFileName: String {
        let cleaned = String(title.map { $0.isNewline || "/\\:*?\"<>|".contains($0) || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } ? "_" : $0 }.prefix(70))
        return (cleaned.isEmpty ? L("Conversation") : cleaned) + ".md"
    }

    /// Searches titles, models, drafts and message bodies.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let check = { (text: String) in text.localizedCaseInsensitiveContains(query) }
        return check(title) || check(modelName ?? model) || check(draft) || messages.contains { check($0.content) }
    }

    static func sorted(_ sessions: [ChatSession]) -> [ChatSession] {
        sessions.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.updatedAt > $1.updatedAt }
    }
}

/// `ai-conversations.sqlite3`. Up to 100 conversations and 32 MiB of serialized content. Owner read/write only.
public final class ChatHistoryStore: Sendable {
    let database: SQLiteDatabase

    public init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        try Self.prepare(database)
        chmod(url.path, 0o600)
    }

    init(database: SQLiteDatabase) throws {
        self.database = database
        try Self.prepare(database)
    }

    private static func prepare(_ database: SQLiteDatabase) throws {
        try database.execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, content TEXT NOT NULL);")
    }

    /// Newest first. Rows that fail validation are skipped so one damaged row never hides the rest.
    public func load() throws -> [ChatSession] {
        do {
            let rows = try database.query("SELECT content FROM conversations ORDER BY updated_at DESC LIMIT 100") { $0.string("content") ?? "" }
            let decoder = JSONDecoder()
            return rows.compactMap { text in
                guard text.utf8.count <= AIContext.maxArchiveBytes, let session = try? decoder.decode(ChatSession.self, from: Data(text.utf8)),
                      (try? session.validate()) != nil else { return nil }
                return session
            }
        } catch {
            throw AIError(L("Could not load conversations."))
        }
    }

    @discardableResult
    public func save(_ session: ChatSession) throws -> ChatSession {
        var session = session
        try session.validate()
        let others = (try? database.scalar("SELECT COUNT(*) FROM conversations WHERE id != ?", [session.id])) ?? 0
        if others >= 100 { throw AIError(L("History holds up to 100 conversations. Delete ones you no longer need.")) }
        session.updatedAt = UsageLedger.now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(session), let content = String(data: data, encoding: .utf8) else {
            throw AIError(L("Could not save the conversation."))
        }
        let otherBytes = (try? database.scalar("SELECT COALESCE(SUM(length(CAST(content AS BLOB))),0) FROM conversations WHERE id != ?", [session.id])) ?? 0
        if Int(otherBytes) + data.count > 32 * 1024 * 1024 {
            throw AIError(L("History storage is full. Delete conversations you no longer need."))
        }
        do {
            try database.run("INSERT INTO conversations (id,updated_at,content) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, content=excluded.content",
                             [session.id, session.updatedAt, content])
        } catch {
            throw AIError(L("Could not save the conversation. Check disk space."))
        }
        return session
    }

    public func delete(_ id: String) throws {
        guard ChatSession.isValidID(id) else { throw AIError(L("Invalid conversation.")) }
        do { try database.run("DELETE FROM conversations WHERE id=?", [id]) } catch { throw AIError(L("Could not delete the conversation.")) }
    }
}
