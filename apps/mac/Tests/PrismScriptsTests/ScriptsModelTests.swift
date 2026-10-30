import AppKit
import Foundation
import PrismKit
import Testing
@testable import PrismScripts

// Ports of `runStore.test.ts` and `ScriptRunPanel.test.tsx` behavior, against the native model.

@MainActor
final class FakeContext: PrismContext {
    let paths: AppPaths
    var previousApplication: NSRunningApplication? { nil }
    var huds: [String] = []
    var hidden = 0

    init(paths: AppPaths) { self.paths = paths }
    func showPalette() {}
    func hidePalette() { hidden += 1 }
    func showPalette(screen: PaletteScreen) {}
    func openSettings(paneID: String?) {}
    func showHUD(_ message: String) { huds.append(message) }
}

@MainActor
struct ModelFixture {
    let scripts = TestDirectory()
    let data = TestDirectory()
    var paths: AppPaths { AppPaths(dataDirectory: data.url) }
    var historyURL: URL { data.url.appending(path: "script-runs-v1.json") }

    func model(directories: [String]? = nil, legacy: [String]? = nil) throws -> ScriptsModel {
        let store = ScriptDirectoriesStore(paths: paths) { legacy }
        if legacy == nil { try store.save(directories ?? [scripts.path]) }
        return ScriptsModel(registry: ScriptRegistry(), directoryStore: store, historyURL: historyURL, pollInterval: .milliseconds(20))
    }
}

@MainActor
func eventually(_ seconds: Double = generousTimeout, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Test func bootstrapRefreshesFoldersAndNeverExecutes() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("marker.sh", "#!/bin/sh\n# @raycast.title Marker\ntouch executed\n")
    let model = try fixture.model()
    await model.bootstrap()
    #expect(model.commands.map(\.title) == ["Marker"])
    #expect(model.lastRefresh?.scannedDirectories == 1)
    #expect(model.commandCountByDirectory[fixture.scripts.path] == 1)
    #expect(model.sessions.isEmpty)
    #expect(!fixture.scripts.exists("executed"), "discovery must never execute")
}

@MainActor
@Test func runsStreamOutputAndPublishCompletion() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("echo.sh", "#!/bin/sh\nprintf first\nsleep 0.3\nprintf ' second'\n")
    let model = try fixture.model()
    await model.bootstrap()
    let id = model.commands[0].id
    await model.start(id, arguments: [])
    #expect(model.session(id).snapshot?.state == .running)
    let finished = await model.waitForCompletion(id)
    #expect(finished?.state == .success)
    #expect(finished?.stdout == "first second")
    await eventually { model.session(id).snapshot?.state == .success }
    #expect(model.session(id).snapshot?.stdout == "first second")
}

@MainActor
@Test func simultaneousStartsRunExactlyOnce() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("count.sh", "#!/bin/sh\necho run >> runs.txt\nsleep 0.2\n")
    let model = try fixture.model()
    await model.bootstrap()
    let id = model.commands[0].id
    async let first: Void = model.start(id, arguments: [])
    async let second: Void = model.start(id, arguments: [])
    _ = await (first, second)
    _ = await model.waitForCompletion(id)
    let runs = try String(contentsOf: fixture.scripts.url.appending(path: "runs.txt"), encoding: .utf8)
    #expect(runs == "run\n")
    #expect(model.registry.nextRunSequence == 1)
}

@MainActor
@Test func restartRestoresInterruptedRunsWithoutPollingCancellingOrRerunning() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("long.sh", "#!/bin/sh\nprintf 'last durable checkpoint'\nsleep 8\n")
    // A previous Prism process saved a running record and exited.
    let previous = ScriptRegistry()
    try previous.initialize(historyURL: fixture.historyURL)
    let scriptID = try previous.refresh(directories: [fixture.scripts.path]).commands[0].id
    let run = ScriptRun(scriptID: scriptID, runID: ScriptIdentifiers.runID(1), startedAtMs: 1, history: previous.history)
    run.stdout.append(Data("last durable checkpoint".utf8))
    try run.checkpoint()

    let model = try fixture.model()
    let actions = ScriptActions(model: model, context: FakeContext(paths: fixture.paths))
    await model.bootstrap()
    #expect(model.commands[0].id == scriptID, "identities survive restart")
    #expect(model.session(scriptID).snapshot?.state == .interrupted)
    #expect(model.session(scriptID).snapshot?.stdout == "last durable checkpoint")
    guard case .push = await actions.runPrimary(scriptID) else { Issue.record("interrupted runs open the screen"); return }
    await model.start(scriptID, arguments: [], rerun: false)
    await model.cancel(scriptID)
    #expect(model.session(scriptID).snapshot?.state == .interrupted)
    #expect(model.registry.nextRunSequence == 1, "nothing was executed")
}

@MainActor
@Test func completedRunIsRestoredAndRerunsOnlyWhenExplicit() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("ok.sh", "#!/bin/sh\necho ok\n")
    let first = try fixture.model()
    await first.bootstrap()
    let id = first.commands[0].id
    await first.start(id, arguments: [])
    _ = await first.waitForCompletion(id)

    let model = try fixture.model()
    await model.bootstrap()
    #expect(model.session(id).snapshot?.state == .success)
    #expect(model.session(id).snapshot?.stdout == "ok\n")
    await model.start(id, arguments: [], rerun: false)
    #expect(model.registry.nextRunSequence == 1)
    await model.start(id, arguments: [], rerun: true)
    #expect(model.registry.nextRunSequence == 2)
    _ = await model.waitForCompletion(id)
}

@MainActor
@Test func cancelsOnlyTheTargetRun() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("a.sh", "#!/bin/sh\nprintf ready\nsleep 8\n")
    fixture.scripts.executable("b.sh", "#!/bin/sh\nprintf ready\nsleep 8\n")
    let model = try fixture.model()
    await model.bootstrap()
    let (a, b) = (model.commands[0].id, model.commands[1].id)
    await model.start(a, arguments: [])
    await model.start(b, arguments: [])
    await model.cancel(a)
    let cancelled = await model.waitForCompletion(a)
    #expect(cancelled?.state == .cancelled)
    #expect(model.session(b).snapshot?.state == .running)
    await model.cancel(b)
    _ = await model.waitForCompletion(b)
}

@MainActor
@Test func startErrorsAreReportedAndKeepThePreviousSnapshot() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("args.sh", "#!/bin/sh\n# prism:argument1={\"type\":\"text\",\"placeholder\":\"Name\"}\necho \"$1\"\n")
    let model = try fixture.model()
    await model.bootstrap()
    let id = model.commands[0].id
    await model.start(id, arguments: [])
    #expect(model.session(id).error == "Argument 1 is required.")
    #expect(model.session(id).errorOperation == .start)
    #expect(model.session(id).snapshot == nil)
    await model.start(id, arguments: ["hello; $(touch nope)"])
    let finished = await model.waitForCompletion(id)
    #expect(finished?.stdout == "hello; $(touch nope)\n")
    #expect(!fixture.scripts.exists("nope"))
}

@MainActor
@Test func failedPersistenceIsRetriedWithAStatusReadOnly() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("slow.sh", "#!/bin/sh\nsleep 0.3\necho done\n")
    let model = try fixture.model()
    await model.bootstrap()
    let id = model.commands[0].id
    await model.start(id, arguments: [])
    // Block the atomic rename target so the terminal checkpoint fails.
    let blocker = URL(filePath: fixture.historyURL.path + ".tmp")
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
    let finished = await model.waitForCompletion(id)
    #expect(finished?.persistenceError != nil)
    try FileManager.default.removeItem(at: blocker)
    await model.retryPersistence(id)
    #expect(model.session(id).snapshot?.persistenceError == nil)
    #expect(model.registry.nextRunSequence == 1)
    #expect(try readHistory(fixture.historyURL).runs.last?.state == .success)
}

@MainActor
@Test func corruptHistoryFailsClosed() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("a.sh", "#!/bin/sh\nexit 0\n")
    try Data("{broken".utf8).write(to: fixture.historyURL)
    let model = try fixture.model()
    await model.bootstrap()
    #expect(model.historyError != nil)
    #expect(model.commands.isEmpty)
    #expect(model.refreshError == "Script history is unavailable. Restart Prism to retry initialization.")
    #expect(try Data(contentsOf: fixture.historyURL) == Data("{broken".utf8))
}

@MainActor
@Test func refreshFailureKeepsThePreviousRegistry() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("a.sh", "#!/bin/sh\nexit 0\n")
    let model = try fixture.model()
    await model.bootstrap()
    #expect(model.commands.count == 1)
    model.addDirectories([URL(filePath: "/nonexistent/prism-scripts")])
    await eventually { model.refreshError != nil }
    #expect(model.commands.count == 1)
    model.removeDirectory("/nonexistent/prism-scripts")
    await eventually { model.refreshError == nil && !model.isRefreshing }
    #expect(model.directories == [fixture.scripts.path])
}

@MainActor
@Test func compactModeReportsTheLastLineAndSilentModeUsesTheHUD() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("compact.sh", "#!/bin/sh\n# @raycast.mode compact\necho one\necho '\\033[32mtwo\\033[0m'\n")
    fixture.scripts.executable("silent.sh", "#!/bin/sh\n# @raycast.mode silent\necho quiet\nexit 3\n")
    let model = try fixture.model()
    let context = FakeContext(paths: fixture.paths)
    let actions = ScriptActions(model: model, context: context)
    await model.bootstrap()
    let compact = model.commands.first { $0.title == "compact" }!.id
    let silent = model.commands.first { $0.title == "silent" }!.id
    guard case .notify(let message) = await actions.runPrimary(compact) else { Issue.record("compact notifies"); return }
    #expect(message == "two")
    guard case .dismiss = await actions.runPrimary(silent) else { Issue.record("silent dismisses"); return }
    await eventually { !context.huds.isEmpty }
    #expect(context.huds == ["Script failed: quiet"])
}

@MainActor
@Test func argumentsAndConfirmationOpenTheScreenFirst() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("args.sh", "#!/bin/sh\n# @raycast.argument1 {\"type\":\"text\",\"placeholder\":\"Query\"}\n")
    fixture.scripts.executable("confirm.sh", "#!/bin/sh\n# @raycast.needsConfirmation true\ntouch confirmed\n")
    let model = try fixture.model()
    let actions = ScriptActions(model: model, context: FakeContext(paths: fixture.paths))
    await model.bootstrap()
    for command in model.commands {
        guard case .push = await actions.runPrimary(command.id) else { Issue.record("\(command.title) must open its screen"); continue }
    }
    try? await Task.sleep(for: .milliseconds(100))
    #expect(!fixture.scripts.exists("confirmed"))
    #expect(model.registry.nextRunSequence == 0)
}

@MainActor
@Test func providerRowsUseTauriIDsAndShowRunningState() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("wait.sh", "#!/bin/sh\n# @raycast.packageName Tools\n# @raycast.icon 🤖\n# prism:keywords=deploy\nsleep 8\n")
    let model = try fixture.model()
    let provider = ScriptsProvider(model: model, actions: ScriptActions(model: model, context: FakeContext(paths: fixture.paths)))
    let items = await provider.results(for: "")
    let id = model.commands[0].id
    #expect(items.map(\.id) == ["script:\(id)"])
    #expect(items[0].candidate.keywords.contains("deploy"))
    #expect(items[0].subtitle == "Tools")
    #expect(items[0].actions.first?.id == "run-script-command")
    guard case .text("🤖") = items[0].icon else { Issue.record("emoji icon"); return }
    await model.start(id, arguments: [])
    let running = await provider.results(for: "")
    #expect(running[0].accessory == "Running")
    #expect(running[0].actions.contains { $0.id == "cancel-script-run" })
    await model.cancel(id)
    _ = await model.waitForCompletion(id)
}

@MainActor
@Test func inlineRowsShowTheFirstLineOfTheLastRun() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("battery.sh", "#!/bin/sh\n# @raycast.mode inline\n# @raycast.refreshTime 1h\necho\necho '87% charged'\necho more\n")
    let model = try fixture.model()
    let actions = ScriptActions(model: model, context: FakeContext(paths: fixture.paths))
    let provider = ScriptsProvider(model: model, actions: actions)
    _ = await provider.results(for: "")
    let id = model.commands[0].id
    guard case .notify(let message) = await actions.runPrimary(id) else { Issue.record("inline notifies"); return }
    #expect(message == "87% charged")
    #expect(await provider.results(for: "")[0].subtitle == "87% charged")
    #expect(model.inlineRefreshIsActive(id))
    model.stopInlineRefresh(id)
    #expect(!model.inlineRefreshIsActive(id))
}

@MainActor
@Test func folderWatcherPicksUpNewScripts() async throws {
    let fixture = ModelFixture()
    let model = try fixture.model()
    model.startWatching()
    await model.bootstrap()
    #expect(model.commands.isEmpty)
    try? await Task.sleep(for: .milliseconds(300))
    fixture.scripts.executable("new.sh", "#!/bin/sh\nexit 0\n")
    await eventually { !model.commands.isEmpty }
    #expect(model.commands.map(\.title) == ["new"])
}

@Test func directoryStoreNormalizesAndImportsTauriPreferencesOnce() throws {
    let data = TestDirectory()
    let paths = AppPaths(dataDirectory: data.url)
    let imported = ScriptDirectoriesStore(paths: paths) { ["  /a ", "/a", "", "/b"] }
    #expect(imported.load() == ["/a", "/b"])
    let later = ScriptDirectoriesStore(paths: paths) { ["/ignored"] }
    #expect(later.load() == ["/a", "/b"], "the import runs only without a native file")
    try later.save(Array(repeating: "/x", count: 3) + (0..<40).map { "/d\($0)" })
    #expect(later.load().count == ScriptLimits.maxDirectories)
    #expect(later.load().first == "/x")
}

@Test func legacyLocalStorageValueIsUTF16() {
    let json = #"{"theme":"dark","scriptDirectories":["/Users/me/Scripts","/tmp/한글"]}"#
    let blob = json.data(using: .utf16LittleEndian)!
    #expect(LegacyScriptDirectories.directories(fromLocalStorageValue: blob) == ["/Users/me/Scripts", "/tmp/한글"])
    #expect(LegacyScriptDirectories.directories(fromLocalStorageValue: Data("{}".utf16LittleEndianBytes)) == nil)
}

@Test func outputHelpersStripANSIAndPickLines() {
    let text = "\u{1B}[1;32mgreen\u{1B}[0m\n\n  last line  \n"
    #expect(ScriptOutput.plain(text) == "green\n\n  last line  \n")
    #expect(ScriptOutput.firstLine(text) == "green")
    #expect(ScriptOutput.lastLine(text) == "last line")
    let segments = ScriptOutput.segments("a\u{1B}[31mb\u{1B}[39mc\u{1B}[2Kd")
    #expect(segments.map(\.text) == ["a", "b", "cd"])
    #expect(segments[1].style.color == 1)
    #expect(ScriptOutput.truncated(String(repeating: "x", count: 200), to: 10).count == 10)
}

@Test func registryMessagesLocalizeWithParameters() {
    // English keeps the message; parameterized keys resolve without crashing.
    #expect(ScriptStrings.localize("Argument 2 is required.") == "Argument 2 is required.")
    #expect(ScriptStrings.localize("Could not save script history: Disk full") == "Could not save script history: Disk full")
    #expect(ScriptStrings.localize("Script timeout must be an integer between 1 and 3600 seconds.").contains("3600"))
}

private extension String {
    var utf16LittleEndianBytes: [UInt8] { Array(data(using: .utf16LittleEndian)!) }
}

@Test func legacyImportReadsWebKitLocalStorageReadOnly() throws {
    let root = TestDirectory()
    let folder = root.url.appending(path: "Default/salt/salt/LocalStorage")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let database = try SQLiteDatabase(url: folder.appending(path: "localstorage.sqlite3"))
    try database.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)")
    let value = #"{"scriptDirectories":["/fixture/scripts"]}"#.data(using: .utf16LittleEndian)!
    try database.run("INSERT INTO ItemTable (key, value) VALUES (?, ?)", ["prism:preferences", value])
    #expect(LegacyScriptDirectories.read(webKitRoot: root.url) == ["/fixture/scripts"])
    #expect(LegacyScriptDirectories.read(webKitRoot: root.url.appending(path: "missing")) == nil)
}

@MainActor
final class ReloadCountingContext: PrismContext {
    let paths: AppPaths
    var previousApplication: NSRunningApplication? { nil }
    var reloads: [String] = []
    init(paths: AppPaths) { self.paths = paths }
    func showPalette() {}
    func hidePalette() {}
    func showPalette(screen: PaletteScreen) {}
    func openSettings(paneID: String?) {}
    func showHUD(_ message: String) {}
    func reloadResults(providerID: String) { reloads.append(providerID) }
}

@MainActor
@Test func rowChangesReloadOnlyTheScriptProviderCoalesced() async throws {
    let fixture = ModelFixture()
    fixture.scripts.executable("chatty.sh", "#!/bin/sh\nfor i in 1 2 3 4 5; do echo $i; sleep 0.05; done\n")
    let model = try fixture.model()
    let context = ReloadCountingContext(paths: fixture.paths)
    await model.bootstrap()
    ScriptsFeature.observeRows(model, context: context)
    let id = model.commands[0].id
    let started = Date()
    await model.start(id, arguments: [])
    _ = await model.waitForCompletion(id)
    await eventually { !context.reloads.isEmpty }
    try? await Task.sleep(for: .milliseconds(900))
    #expect(Set(context.reloads) == [ScriptsProvider.providerID])
    // At most one reload per 400 ms window, however much output streamed in that time.
    let windows = Int(Date().timeIntervalSince(started) / 0.4) + 1
    #expect(context.reloads.count <= windows, "streaming output is coalesced, got \(context.reloads.count) in \(windows) windows")
}
