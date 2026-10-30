import Foundation
import PrismKit
import Testing
@testable import PrismAI

struct KeySessionTests {
    @Test func settingsDenialDoesNotBlockFeatureAuthorization() throws {
        var session = KeySession()
        #expect(throws: AIError.self) { try session.loadSilent { throw AIError("interaction required") } }
        #expect(try session.load { Data("fixture".utf8) } == Data("fixture".utf8))
        #expect(try session.loadSilent { Issue.record("reuse authorized access"); return nil } != nil)
    }

    @Test func settingsProbeDoesNotClearACancelledFeatureRequest() {
        var session = KeySession()
        #expect(throws: AIError.self) { try session.load { throw AIError("canceled") } }
        #expect(throws: AIError.self) { try session.loadSilent { throw AIError("interaction required") } }
        #expect(throws: AIError("canceled")) { try session.load { Issue.record("do not reopen canceled dialog"); return nil } }
    }

    @Test func repeatedReadsShareOneAuthorizationAndReplacementInvalidates() throws {
        var session = KeySession()
        #expect(session.peek() == nil)
        _ = try session.load { Data("fixture-first".utf8) }
        for _ in 0..<20 { #expect(try session.load { Issue.record("must not reauthorize"); return nil } == Data("fixture-first".utf8)) }
        session.replace(Data("fixture-second".utf8))
        #expect(session.peek() == Data("fixture-second".utf8))
        session.clear()
        #expect(session.peek() == nil)
        #expect(try session.load { nil } == nil)
    }

    @Test func cancelledDialogIsNotReopenedByQueuedCallsButExpires() throws {
        var session = KeySession()
        let start = Date()
        #expect(throws: AIError.self) { try session.load({ throw AIError("canceled") }, now: start) }
        #expect(throws: AIError("canceled")) { try session.load({ Issue.record("queued caller must not prompt"); return nil }, now: start) }
        #expect(try session.load({ Data("fixture".utf8) }, now: start.addingTimeInterval(6)) != nil)
    }

    @Test func explicitAuthorizationCanRetryARecentDenial() throws {
        var session = KeySession()
        #expect(throws: AIError.self) { try session.load { throw AIError("authorization required") } }
        session.allowRetry()
        #expect(try session.load { Data("fixture".utf8) } != nil)
        session.allowRetry()
        #expect(try session.load { Issue.record("an authorized key stays cached"); return nil } != nil)
    }

    @Test func savedKeyInfoNeverExposesTheSecret() {
        #expect(!AIKeyInfo.from(nil).configured)
        #expect(AIKeyInfo.from(Data("short".utf8)).maskedKey == "•••• ••••")
        #expect(AIKeyInfo.from(Data("fixture-secret-1234".utf8)).maskedKey == "•••• •••• 1234")
    }

    @Test func keychainErrorsDistinguishCancellationAuthorizationAndFailure() {
        #expect(AIKeychain.readError(-128, allowPrompt: true).contains("canceled"))
        #expect(AIKeychain.readError(-25293, allowPrompt: true).contains("denied"))
        #expect(AIKeychain.readError(-25308, allowPrompt: true).contains("could not show"))
        #expect(AIKeychain.readError(-25308, allowPrompt: false) == "Keychain authorization is required.")
        #expect(AIKeychain.readError(-36, allowPrompt: true).contains("-36"))
    }

    /// Uses an isolated, test-only service in the login keychain. Never touches `dev.prism.desktop.ai`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRISM_KEYCHAIN_TESTS"] == "1"))
    func isolatedKeychainRoundTrip() throws {
        let service = "dev.prism.test.ai.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        let store = AIKeyStore(service: service, compatibleService: service + ".compatible")
        defer { try? store.keychain.delete(account: "openai") }
        #expect(try store.info(.openai).configured == false)
        #expect(try store.save(.openai, key: " fixture-key-1234 ").maskedKey == "•••• •••• 1234")
        #expect(try store.keychain.read(account: "openai", allowPrompt: false) == Data("fixture-key-1234".utf8))
        #expect(try store.keychain.exists(account: "openai"))
        _ = try store.save(.openai, key: "fixture-replacement-5678")
        #expect(try store.key(for: .openai) == Data("fixture-replacement-5678".utf8))
        #expect(try store.cachedKey(for: .openai) == Data("fixture-replacement-5678".utf8))
        try store.delete(.openai)
        #expect(try store.keychain.read(account: "openai", allowPrompt: false) == nil)
        #expect(throws: AIError.self) { try store.save(.openai, key: "has space") }
    }
}

struct PreferenceStoreTests {
    @Test func selectionSurvivesReopenAndRejectsInvalidReplacement() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AISelectionStore(url: directory.appending(path: "ai-selection-v1.json"))
        #expect(try store.load() == nil)
        try store.save(AISelection(provider: .vercel, model: "creator/model", modelName: "My model"))
        #expect(try AISelectionStore(url: store.url).load()?.modelName == "My model")
        #expect(throws: AIError.self) { try store.save(AISelection(provider: .vercel, model: "bad model")) }
        #expect(try store.load()?.model == "creator/model")
        // The Tauri file writes modelName as null.
        try Data(#"{"provider":"openrouter","model":"x/y","modelName":null}"#.utf8).write(to: store.url)
        #expect(try store.load() == AISelection(provider: .openrouter, model: "x/y"))
    }

    @Test func baseURLsPreservePrefixesAndRejectAmbiguousTargets() throws {
        #expect(try CompatibleConnection.normalize(" http://localhost:11434/v1 ") == "http://localhost:11434/v1/")
        #expect(try CompatibleConnection.normalize("https://example.test/proxy/v1/") == "https://example.test/proxy/v1/")
        for input in ["", "file:///tmp/key", "https://key@example.test/v1", "https://example.test/v1?key=secret", "https://example.test/v1#key",
                      "https://example.test/v1/chat/completions", "https://example.test/v1/models"] {
            #expect(throws: AIError.self, "\(input)") { try CompatibleConnection.normalize(input) }
        }
    }

    @Test func connectionPersistsWithoutCredentialsAndRejectsCorruption() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompatibleStore(url: directory.appending(path: "ai-compatible-v1.json"))
        let keys = AIKeyStore(service: "dev.prism.test.unused", compatibleService: "dev.prism.test.unused.compatible")
        #expect(try store.load().baseUrl.isEmpty)
        let saved = try store.save(baseUrl: "http://localhost:11434/v1", key: nil, keys: keys)
        #expect(saved == CompatibleConnection(baseUrl: "http://localhost:11434/v1/", hasKey: false))
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\"baseUrl\"") && text.contains("\"hasKey\":false"))
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: AIError.self) { try store.load() }
    }

    @Test func legacyWebOptOutIsIgnoredAndLimitsAreValidated() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIToolStore(url: directory.appending(path: "ai-tools-v1.json"))
        #expect(try store.load() == AIToolSettings())
        try Data(#"{"webSearch":false,"localFiles":false,"maxOutputTokens":4096,"folders":[]}"#.utf8).write(to: store.url)
        let value = try store.load()
        #expect(value.webSearch && !value.localFiles && value.maxOutputTokens == 4096)
        let saved = try store.set(localFiles: true, maxOutputTokens: 32_768)
        #expect(saved.localFiles && saved.maxOutputTokens == 32_768)
        #expect(!(try String(contentsOf: store.url, encoding: .utf8)).contains("webSearch"))
        #expect(throws: AIError.self) { try store.set(localFiles: true, maxOutputTokens: 1000) }
    }

    @Test func foldersComeFromTheChooserAndAreBounded() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIToolStore(url: directory.appending(path: "ai-tools-v1.json"))
        let folder = directory.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let added = try store.addFolder(folder)
        #expect(added.localFiles && added.folders.count == 1 && added.folders[0].id.hasPrefix("folder-"))
        #expect(try store.addFolder(folder).folders.count == 1)
        #expect(throws: AIError.self) { try store.addFolder(URL(filePath: "/")) }
        #expect(try store.removeFolder(added.folders[0].id).folders.isEmpty)
    }
}

struct LocalToolTests {
    @Test func filesRequireAGrantAndCannotEscapeThroughPathsOrLinks() throws {
        let base = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = URL(filePath: AIFileIO.canonicalPath(base.path)!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try Data("fixture content".utf8).write(to: root.appending(path: "docs/readme.md"))
        try Data("not exposed".utf8).write(to: root.appending(path: ".env"))
        try Data("not exposed".utf8).write(to: root.appending(path: "credentials.json"))
        let settings = AIToolSettings(localFiles: true, folders: [AIFolderGrant(id: "fixture", path: root.path)])
        let read = { (path: String) in try AITools.executeLocal(settings, name: "read_local_file", arguments: ["folder_id": "fixture", "path": .string(path)]) }
        #expect(try read("docs/readme.md")["content"] == "fixture content")
        for path in ["../readme.md", "/etc/passwd", ".env", "credentials.json", "docs/../../outside.md"] {
            #expect(throws: AIError.self, "\(path)") { try read(path) }
        }
        #expect(throws: AIError.self) { try AITools.executeLocal(settings, name: "read_local_file", arguments: ["folder_id": "other", "path": "docs/readme.md"]) }
        #expect(throws: AIError.self) { try AITools.executeLocal(AIToolSettings(), name: "read_local_file", arguments: ["folder_id": "fixture", "path": "docs/readme.md"]) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "alias"), withDestinationURL: root.appending(path: "docs"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked.md"), withDestinationURL: root.appending(path: "docs/readme.md"))
        try FileManager.default.linkItem(at: root.appending(path: "docs/readme.md"), to: root.appending(path: "hard.md"))
        for path in ["alias/readme.md", "linked.md", "hard.md"] {
            #expect(throws: AIError.self, "\(path)") { try read(path) }
        }
        let list = try AITools.executeLocal(settings, name: "list_local_files", arguments: ["folder_id": "fixture", "path": ""]).text
        #expect(list.contains("docs"))
        #expect(!list.contains("credentials") && !list.contains(".env") && !list.contains("linked") && !list.contains("hard.md"))
        #expect(throws: AIError.self) { try AITools.executeLocal(settings, name: "run_shell", arguments: ["folder_id": "fixture", "path": ""]) }
    }

    @Test func searchIsAvailableByDefaultAndFilesNeedFolders() {
        #expect(AITools.definitions(AIToolSettings(), webFunction: true).count == 1)
        #expect(AITools.definitions(AIToolSettings(), webFunction: false).isEmpty)
        var settings = AIToolSettings(localFiles: true)
        #expect(AITools.definitions(settings, webFunction: true).count == 1)
        settings.folders.append(AIFolderGrant(id: "one", path: "/fixture"))
        #expect(AITools.definitions(settings, webFunction: true).count == 3)
        #expect(AITools.definitions(settings, webFunction: false).count == 2)
        #expect(AITools.definitions(settings, webFunction: false)[0]["function"]["description"].string?.contains("\"name\":\"fixture\"") == true)
    }
}
