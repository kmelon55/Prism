import AppKit
import PrismKit
import SwiftUI
import Testing
@testable import PrismAI

/// Renders the chat window, model picker and settings from fixture data to PNG files for visual review.
/// Opt-in: `PRISM_AI_SNAPSHOT_DIR=<dir> [PRISM_AI_SNAPSHOT_LANGUAGE=ko] swift test --filter SnapshotTests`.
@MainActor
struct SnapshotTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["PRISM_AI_SNAPSHOT_DIR"]

    @Test(.enabled(if: directory != nil))
    func renderChatAndSettings() async throws {
        let output = URL(filePath: Self.directory!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suffix = ProcessInfo.processInfo.environment["PRISM_AI_SNAPSHOT_LANGUAGE"].map { "-\($0)" } ?? ""

        let data = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let catalog = #"{"data":[{"id":"anthropic/claude-sonnet-4.5","name":"Claude Sonnet 4.5","type":"language","modalities":{"input":["text","image"],"output":["text"]},"context_window":200000,"supported_parameters":["tools"],"pricing":{"input":"0.000003","output":"0.000015"}},{"id":"google/gemini-2.5-flash-lite","name":"Gemini 2.5 Flash Lite","type":"language","modalities":{"input":["text","image"],"output":["text"]},"context_window":1048576,"supported_parameters":["tools"],"pricing":{"input":"0.0000001","output":"0.0000004"}},{"id":"openai/gpt-5","name":"GPT-5","type":"language","modalities":{"input":["text","image"],"output":["text"]},"context_window":400000,"supported_parameters":["tools"],"pricing":{"input":"0.00000125","output":"0.00001"}},{"id":"zai/glm-5.3-flash","name":"GLM 5.3 Flash","type":"language","modalities":{"input":["text"],"output":["text"]},"context_window":128000,"pricing":{"input":"0","output":"0"}}]}"#
        let transport = MockTransport(Array(repeating: .init(chunks: [Data(catalog.utf8)]), count: 20))
        let service = AIService(paths: AppPaths(dataDirectory: data), keys: AIKeyStore(service: "dev.prism.test.snapshot", compatibleService: "dev.prism.test.snapshot.c"),
                                transport: transport, cache: AIModelCache())
        _ = try service.compatible.save(baseUrl: "http://localhost:11434/v1", key: nil, keys: service.keys)
        try service.selection.save(AISelection(provider: .compatible, model: "llama3.3", modelName: "Llama 3.3"))
        let store = try ChatHistoryStore(url: data.appending(path: "ai-conversations.sqlite3"))
        try seed(store)
        if let ledger = service.ledger { try seed(ledger) }

        let model = ChatModel(service: service, store: store)
        model.load()
        try await Task.sleep(for: .milliseconds(600))

        for appearance in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            if let first = model.sessions.first(where: { $0.title.hasPrefix("Release") }) { model.select(first.id) }
            try await Task.sleep(for: .milliseconds(300))
            await snapshot(ChatRootView(model: model), size: CGSize(width: 1080, height: 760), to: output.appending(path: "chat-\(appearance)\(suffix).png"))
            // Scroll views do not draw in the test host, so the transcript is also rendered on its own.
            await snapshot(VStack(alignment: .leading, spacing: 18) { TranscriptRows(model: model, display: model.displayMessages, offset: 0) }
                .frame(width: 720).padding(24), size: CGSize(width: 768, height: 980), to: output.appending(path: "transcript-\(appearance)\(suffix).png"))
            model.newConversation()
            try await Task.sleep(for: .milliseconds(300))
            await snapshot(ChatRootView(model: model), size: CGSize(width: 900, height: 600), to: output.appending(path: "chat-empty-\(appearance)\(suffix).png"))
            await snapshot(ModelPickerView(service: service, selection: AISelection(provider: .vercel, model: "openai/gpt-5", modelName: "GPT-5"), onSelect: { _ in }, onSettings: {}),
                           size: CGSize(width: 600, height: 500), to: output.appending(path: "picker-\(appearance)\(suffix).png"), settle: 700)
            await snapshot(AISettingsView(service: service), size: CGSize(width: 560, height: 1500), to: output.appending(path: "settings-\(appearance)\(suffix).png"), settle: 900)
        }
    }

    /// SwiftUI lists and scroll views update through the run loop, which the test runner does not spin by itself.
    private func spin(_ milliseconds: Int) {
        let end = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02))) }
    }

    private func seed(_ store: ChatHistoryStore) throws {
        let selection = AISelection(provider: .compatible, model: "llama3.3", modelName: "Llama 3.3")
        var release = ChatSession(selection: selection, title: "Release checklist for 0.2")
        release.messages = [
            ChatTurn(role: "user", content: "Summarize the release steps and show the signing command. 서명 순서도 알려줘."),
            ChatTurn(role: "assistant", content: """
            ## Release steps

            1. **Bump** the version in `Package.swift` and the changelog.
            2. Build and sign:
               - Use the persistent certificate
               - [x] Never regenerate keys
            3. Notarize and staple.

            > Keep the installed app's signing identity. 설치된 앱의 서명은 유지하세요.

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
        release.draft = "Also list rollback steps"
        try store.save(release)
        var pinned = ChatSession(selection: AISelection(provider: .vercel, model: "anthropic/claude-sonnet-4.5", modelName: "Claude Sonnet 4.5"), title: "번역 메모", pinned: true)
        pinned.messages = [ChatTurn(role: "user", content: "안녕하세요를 영어로"), ChatTurn(role: "assistant", content: "**Hello** — or *Hi* informally.", modelName: "Claude Sonnet 4.5")]
        try store.save(pinned)
        try store.save(ChatSession(selection: selection, draft: "Draft about SwiftUI layout"))
    }

    private func seed(_ ledger: UsageLedger) throws {
        let start = UsageLedger.monthStart()
        for (offset, feature, provider, model, cost, input, output) in [
            (0, "chat", "vercel", "anthropic/claude-sonnet-4.5", 0.012, 1200, 400), (1, "chat", "vercel", "openai/gpt-5", 0.02, 3000, 900),
            (2, "cleanup", "openai", "gpt-5-mini", 0.001, 300, 80), (3, "chat_summary", "vercel", "anthropic/claude-sonnet-4.5", 0.004, 2500, 300),
            (4, "transcription", "local", "whisper", -1.0, 0, 0),
        ] as [(Int, String, String, String, Double, Int, Int)] {
            let id = try ledger.insert(feature: feature, provider: provider, model: model, at: start + Int64(offset) * 86_400_000 + 3_600_000)
            try ledger.update(id, measurement: UsageMeasurement(inputTokens: cost < 0 ? nil : input, outputTokens: cost < 0 ? nil : output,
                                                                costUSD: cost < 0 ? nil : cost, costKind: cost < 0 ? "unknown" : "reported"), status: "completed")
        }
    }

    private func snapshot<Content: View>(_ view: Content, size: CGSize, to url: URL, settle: Int = 450) async {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(settle))
        spin(200)
        hosting.layoutSubtreeIfNeeded()
        // Layer rendering captures SwiftUI scroll content that `cacheDisplay` skips outside a running app.
        let scale = 2
        guard let layer = hosting.layer,
              let context = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
