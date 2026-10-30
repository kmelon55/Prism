import CryptoKit
import Foundation
import Testing
@testable import PrismDictation

/// Ports of `dictation/catalog.rs`, `dictation/local_models.rs` and `DictationModelPicker.test.tsx`.
struct CatalogTests {
    @Test func vercelFiltersLiveResponseAndKeepsRealtimeDisabled() throws {
        let body = #"{"data":[{"id":"chat","type":"language"},{"id":"old","type":"transcription"},{"id":"google/gemini-3.5-transcribe-live","type":"transcription","supported_specifications":["v4"]},{"id":"openai/gpt-4o-mini-transcribe","type":"transcription","supported_specifications":["v4"],"pricing":{"input":"0.1"}}]}"#
        let models = try SpeechModelCatalog.decode(provider: .vercel, body: Data(body.utf8))
        #expect(models.count == 2)
        #expect(models[0].id == "openai/gpt-4o-mini-transcribe" && models[0].batchCompatible)
        #expect(!models[1].batchCompatible)
        #expect(models[0].pricing["input"] == "0.1")
    }

    @Test func membershipIsLiveAndAudioChatIsNotSpeechToText() throws {
        let data = Data(#"{"data":[{"id":"gpt-4o-audio"},{"id":"gpt-transcribe"},{"id":"gpt-4o-mini-transcribe-2025-12-15"},{"id":"gpt-4o-transcribe-diarize"},{"id":"gpt-4o-transcribe-unknown"}]}"#.utf8)
        let models = try SpeechModelCatalog.decode(provider: .openai, body: data)
        #expect(models.count == 3)
        #expect(models.first { $0.id.contains("diarize") }?.batchCompatible == false)
        #expect(try SpeechModelCatalog.decode(provider: .groq, body: data).isEmpty)
        #expect(try SpeechModelCatalog.decode(provider: .custom, body: data).isEmpty)
        #expect(try SpeechModelCatalog.decode(provider: .vercel, body: Data(#"{"data":[]}"#.utf8)).isEmpty)
        #expect(throws: DictationError.self) { try SpeechModelCatalog.decode(provider: .vercel, body: Data(#"{"error":"secret"}"#.utf8)) }
    }

    @Test func publicCatalogSnapshotUsesWhispBatchFilterAndOrder() throws {
        let rows = try SpeechModelCatalog.decode(provider: .vercel, body: Data(vercelCatalogFixture.utf8))
        #expect(rows.count == 9)
        #expect(rows.filter(\.batchCompatible).count == 7)
        #expect(rows[0].id == "openai/gpt-4o-mini-transcribe")
        #expect(rows.contains { $0.id == "spacexai/grok-stt" && $0.batchCompatible })
    }

    @Test func catalogCannotRedirectSharedKeysToOtherHosts() throws {
        #expect(throws: DictationError.self) { try SpeechModelCatalog.endpoint(provider: .openai, baseURL: "https://evil.test/v1") }
        #expect(throws: DictationError.self) { try SpeechModelCatalog.endpoint(provider: .custom, baseURL: "http://evil.test/v1") }
        #expect(try SpeechModelCatalog.endpoint(provider: .custom, baseURL: "http://127.0.0.1:9000/v1/audio/transcriptions") == "http://127.0.0.1:9000/v1/models")
        #expect(try SpeechModelCatalog.endpoint(provider: .vercel, baseURL: "https://ai-gateway.vercel.sh/v4/ai") == "https://ai-gateway.vercel.sh/v1/models")
    }

    @Test func catalogTransportOnlyGetsAndNeverEchoesErrors() async throws {
        let session = MockHTTP.session()
        MockHTTP.serve("catalog-ok.invalid", .init(body: Data(#"{"data":[]}"#.utf8)))
        let body = try await SpeechModelCatalog.fetch("https://catalog-ok.invalid/v1/models", apiKey: "fixture-key", session: session)
        #expect(body == Data(#"{"data":[]}"#.utf8))
        let request = try #require(MockHTTP.requests(for: "catalog-ok.invalid").first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")

        MockHTTP.serve("catalog-401.invalid", .init(status: 401, body: Data("fixture-secret".utf8)))
        do {
            _ = try await SpeechModelCatalog.fetch("https://catalog-401.invalid/v1/models", apiKey: nil, session: session)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.localizedDescription.contains("401") && !error.localizedDescription.contains("fixture-secret"))
        }
        #expect(MockHTTP.requests(for: "catalog-401.invalid").first?.value(forHTTPHeaderField: "Authorization") == nil)

        MockHTTP.serve("catalog-big.invalid", .init(body: Data(repeating: 32, count: 4 * 1_048_576 + 1)))
        await #expect(throws: DictationError.self) {
            _ = try await SpeechModelCatalog.fetch("https://catalog-big.invalid/v1/models", apiKey: nil, session: session)
        }
    }

    @Test func redirectsAreNotFollowed() async throws {
        // The production session refuses redirects; a 302 surfaces as an error with its status.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        MockHTTP.serve("catalog-302.invalid", .init(status: 302, headers: ["Location": "https://should-never-contact.invalid/"], body: Data("fixture-secret".utf8)))
        do {
            _ = try await SpeechModelCatalog.fetch("https://catalog-302.invalid/v1/models", apiKey: "fixture-key", session: MockHTTP.session())
            Issue.record("Expected a failure")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-secret"))
        }
        #expect(MockHTTP.requests(for: "should-never-contact.invalid").isEmpty)
    }

    @Test func xaiUsesAFixedEndpointWithoutACatalogRequest() async throws {
        let catalog = try await SpeechModelCatalog.load(provider: .xai, baseURL: "https://api.x.ai/v1", apiKey: nil, session: MockHTTP.session())
        #expect(catalog.mode == .fixed && catalog.models.isEmpty && catalog.source == "https://api.x.ai/v1/stt")
    }

    @Test func pricesComeOnlyFromTheResponse() {
        func model(_ pricing: [String: String], free: Bool = false) -> SpeechModel {
            SpeechModel(id: "x", name: "x", description: "", ownedBy: "", batchCompatible: true, unavailableReason: nil, free: free, pricing: pricing)
        }
        #expect(model(["transcription_duration_cost_per_second": "0.0001"]).priceText == "$0.36/hr")
        #expect(model(["audio_input_token_cost": "0.000001", "output": "0.000002"]).priceText.hasPrefix("$1.00 / $2.00"))
        #expect(model([:]).priceText == "Price unavailable")
        #expect(model([:], free: true).priceText == "Free")
    }

    // MARK: Local models

    @Test func rejectsUnlistedModelNamesAndPaths() {
        for id in ["../large-v3", "https://example.com/model", "large-v3.en", ""] { #expect(LocalModel.find(id) == nil) }
        for model in LocalModel.all {
            #expect(LocalModel.find(model.id)?.bytes == model.bytes)
            #expect(model.sha256.count == 64)
            #expect(model.downloadURL.absoluteString.contains(LocalModel.revision))
        }
    }

    @Test func validatesBytesAndChecksumIndependently() throws {
        let fixture = LocalModel(id: "test", name: "test", description: "", bytes: 3,
                                 sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try LocalModelFiles.verify(bytes: 3, digest: SHA256.hash(data: Data("abc".utf8)), model: fixture)
        #expect(throws: DictationError.self) { try LocalModelFiles.verify(bytes: 2, digest: SHA256.hash(data: Data("abc".utf8)), model: fixture) }
        #expect(throws: DictationError.self) { try LocalModelFiles.verify(bytes: 3, digest: SHA256.hash(data: Data("abd".utf8)), model: fixture) }
        let folder = TemporaryDirectory()
        let file = try folder.file("abc.bin", contents: Data("abc".utf8))
        try LocalModelFiles.verifyExisting(file, model: fixture)
    }

    @Test func partialDownloadsAreNotReady() throws {
        let folder = TemporaryDirectory()
        let model = LocalModel.all[0]
        let target = try folder.file(model.fileName, contents: Data("partial".utf8))
        #expect(!LocalModelFiles.isComplete(target, model: model))
        #expect(LocalModelFiles.isComplete(target, model: LocalModel(id: "p", name: "", description: "", bytes: 7, sha256: "")))
    }

    @Test func formatsSizesLikeTheTauriPicker() {
        #expect(LocalModel.sizeText(574_041_195) == "574 MB")
        #expect(LocalModel.sizeText(1_624_555_275) == "1.62 GB")
    }

    @Test @MainActor func managerListsOnlyCompleteModels() throws {
        let folder = TemporaryDirectory()
        let manager = LocalModelManager(paths: .init(dataDirectory: folder.url))
        try FileManager.default.createDirectory(at: manager.directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: manager.directory.appending(path: LocalModel.all[0].fileName))
        manager.refresh(preferredWhisperPath: "/nonexistent")
        #expect(manager.installed.isEmpty)
        #expect(manager.download == nil)
    }
}
