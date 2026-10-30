import Foundation
import PrismKit
import Testing
@testable import PrismAI

/// Seeds a throwaway data folder with conversations for snapshot renders of the chat screen.
/// Opt-in: `PRISM_AI_SEED_DIR=<dir> swift test --filter ChatSeedTests`.
struct ChatSeedTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["PRISM_AI_SEED_DIR"]

    @Test(.enabled(if: directory != nil))
    func seed() throws {
        let data = URL(filePath: Self.directory!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let service = AIService(paths: AppPaths(dataDirectory: data), keys: AIKeyStore(service: "dev.prism.test.seed", compatibleService: "dev.prism.test.seed.c"))
        _ = try service.compatible.save(baseUrl: "http://localhost:11434/v1", key: nil, keys: service.keys)
        let selection = AISelection(provider: .compatible, model: "llama3.3", modelName: "Llama 3.3")
        try service.selection.save(selection)
        let store = try ChatHistoryStore(url: data.appending(path: "ai-conversations.sqlite3"))
        var release = ChatSession(selection: selection, title: "Release checklist for 0.2")
        release.messages = [
            ChatTurn(role: "user", content: "Summarize the release steps and show the signing command."),
            ChatTurn(role: "assistant", content: """
            ## Release steps

            1. **Bump** the version in `Package.swift` and the changelog.
            2. Build and sign:
               - Use the persistent certificate
               - [x] Never regenerate keys
            3. Notarize and staple.

            > Keep the installed app's signing identity.

            ```sh
            pnpm macos:install --sign "Developer ID Application"
            ```

            | Step | Owner | Time |
            |:-----|:-----:|-----:|
            | Build | CI | 4 min |
            | Notarize | Apple | ~10 min |

            See https://developer.apple.com/documentation/security for details.
            """, modelName: "Llama 3.3"),
        ]
        release.updatedAt += 10_000
        try store.save(release)
        var pinned = ChatSession(selection: AISelection(provider: .vercel, model: "anthropic/claude-sonnet-4.5", modelName: "Claude Sonnet 4.5"), title: "번역 메모", pinned: true)
        pinned.messages = [ChatTurn(role: "user", content: "안녕하세요를 영어로"), ChatTurn(role: "assistant", content: "**Hello** — or *Hi* informally.", modelName: "Claude Sonnet 4.5")]
        try store.save(pinned)
        try store.save(ChatSession(selection: selection, draft: "Draft about SwiftUI layout"))
    }
}
