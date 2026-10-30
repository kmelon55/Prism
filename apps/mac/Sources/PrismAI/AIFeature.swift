import AppKit
import PrismCore
import PrismKit
import SwiftUI

/// AI chat, providers, history, usage and tools.
public enum AIFeature {
    public static let chatCommandID = "prism:ai-chat"
    public static let captureCommandID = "prism:capture-ai"
    public static let settingsPaneID = "ai"

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let runtime = AIRuntime(context: context)
        let service = runtime.service
        SharedModelPicker.make = { title, current, onSelect, onDismiss in
            let selection = current.flatMap { choice in
                AIProvider(rawValue: choice.provider).map { AISelection(provider: $0, model: choice.model, modelName: choice.modelName) }
            } ?? .empty
            return AnyView(ModelPickerView(service: service, selection: selection, purpose: .other(title), onSelect: { chosen in
                try await onSelect(.init(provider: chosen.provider.rawValue, model: chosen.model, modelName: chosen.modelName))
            }, onSettings: { context.openSettings(paneID: settingsPaneID) }, onDismiss: onDismiss))
        }
        return FeatureContribution(
            providers: [AICommandProvider(runtime: runtime), AskAIProvider(runtime: runtime)],
            settingsPanes: [
                SettingsPane(id: settingsPaneID, title: L("AI"), systemImage: "sparkles", order: 20,
                             keywords: ["Current model", "Provider", "API key", "Tools and permissions", "Automatic web search",
                                        "Allow local file reading", "Output and reasoning limit", "AI usage", "Default model"].map { L(String.LocalizationValue($0)) }
                                 + ["OpenAI", "OpenRouter", "Vercel AI Gateway", "Keychain"]) {
                    AISettingsView(service: runtime.service)
                },
            ]
        )
    }
}

/// Owns the provider service and creates the chat window on first use, so launch stays light.
@MainActor
final class AIRuntime {
    let service: AIService
    private weak var context: (any PrismContext)?
    private var controller: ChatWindowController?

    init(context: any PrismContext) {
        self.context = context
        service = AIService(paths: context.paths)
    }

    var chat: ChatWindowController? {
        if let controller { return controller }
        guard let context else { return nil }
        let store = try? ChatHistoryStore(url: context.paths.file("ai-conversations.sqlite3"))
        let created = ChatWindowController(model: ChatModel(service: service, store: store), context: context)
        controller = created
        return created
    }

    /// Opens the chat with the palette query as an unsent draft. "ai", "chat" and "대화" just open it.
    func openChat(query: String) -> PaletteActionOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = trimmed.range(of: #"^(ai|chat|대화)$"#, options: [.regularExpression, .caseInsensitive]) != nil ? "" : query
        guard let screen = chat?.screen(draft: draft) else { return .keepOpen }
        return .push(screen)
    }

    func captureAndAsk() async {
        context?.hidePalette()
        do {
            try? await Task.sleep(for: .milliseconds(180))
            if let image = try await Task.detached(operation: { try ScreenRegionCapture.capture() }).value,
               let screen = chat?.screen(image: image) {
                context?.showPalette(screen: screen)
            }
        } catch {
            context?.showHUD((error as? AIError)?.message ?? L("Could not capture the screen."))
        }
    }
}

@MainActor
final class AICommandProvider: PaletteProvider {
    let id = "ai-commands"
    private let runtime: AIRuntime

    init(runtime: AIRuntime) {
        self.runtime = runtime
    }

    func results(for query: String) async -> [PaletteItem] {
        let runtime = runtime
        let chat = SearchCandidate(
            id: AIFeature.chatCommandID,
            title: L("AI Chat"),
            subtitle: L("Chat, translate and summarize with your own API key"),
            section: L("Productivity"),
            keywords: ["ai", "chat", "ask", "openai", "openrouter", "byok", "대화", "질문", "번역", "요약", "인공지능"],
            searchAliases: ["AI Chat", "AI 채팅"]
        )
        let capture = SearchCandidate(
            id: AIFeature.captureCommandID,
            title: L("Capture and Ask AI"),
            subtitle: L("Select a screen region and start a conversation"),
            section: L("Productivity"),
            keywords: ["screenshot", "screen", "capture", "region", "quick ai", "캡처", "화면", "영역", "스크린샷"]
        )
        return [
            PaletteItem(candidate: chat, icon: .symbol("sparkles", tint: .purple), accessory: L("Command"), actions: [
                PaletteAction(id: "open-ai-chat", title: L("Open AI Chat"), systemImage: "sparkles") {
                    runtime.openChat(query: query)
                },
            ]),
            PaletteItem(candidate: capture, icon: .symbol("viewfinder", tint: .purple), accessory: L("Command"), actions: [
                PaletteAction(id: "capture-ai", title: L("Capture screen region"), systemImage: "viewfinder") {
                    Task { await runtime.captureAndAsk() }
                    return .dismiss
                },
            ]),
        ]
    }
}

/// "Ask AI" fallback after the ranked results. It shares the AI Chat command ID, so it only appears when the
/// command row itself does not match the query.
@MainActor
final class AskAIProvider: PaletteProvider {
    let id = "ai-ask"
    let ranking: PaletteRanking = .appended
    private let runtime: AIRuntime

    init(runtime: AIRuntime) {
        self.runtime = runtime
    }

    func results(for query: String) async -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let runtime = runtime
        let candidate = SearchCandidate(id: AIFeature.chatCommandID, title: L("Ask AI"), subtitle: trimmed, section: L("AI Chat"))
        return [PaletteItem(candidate: candidate, icon: .symbol("sparkles", tint: .purple), accessory: L("AI Chat"), actions: [
            PaletteAction(id: "open-ai-chat", title: L("Ask AI"), systemImage: "sparkles") {
                runtime.openChat(query: query)
            },
        ])]
    }
}
