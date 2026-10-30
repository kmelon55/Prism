import Foundation
import Testing
@testable import PrismScripts

// Ports of the `script_commands.rs` tests.

@Test func acceptsOnlyGeneratedIdentifierShape() {
    #expect(throws: Never.self) { try ScriptIdentifiers.validateScriptID("sc_0000000000000001") }
    for value in ["", "sc_0000000000000000", "sc_1", "sc_000000000000000A", "../sc_0000000000000001", "script_0000000000000001"] {
        #expect(throws: ScriptError.self, "accepted \(value)") { try ScriptIdentifiers.validateScriptID(value) }
    }
    #expect(ScriptIdentifiers.scriptID(26) == "sc_000000000000001a")
    #expect(ScriptIdentifiers.runID(1) == "sr_0000000000000001")
}

@Test func rejectsRelativeAndNonDirectoryRoots() {
    #expect(throws: ScriptError.self) { try ScriptFileRules.canonicalizeDirectories(["relative/scripts"]) }
    let directory = TestDirectory()
    directory.file("file", "not a directory")
    #expect(throws: ScriptError.self) { try ScriptFileRules.canonicalizeDirectories([directory.url.appending(path: "file").path]) }
}

@Test func canonicalScriptPathsCannotEscapeTheSelectedRoot() {
    let directory = TestDirectory()
    let outside = TestDirectory()
    outside.file("outside.sh", "outside")
    #expect(throws: ScriptError.self) {
        try ScriptFileRules.canonicalScriptPath(root: directory.path, candidate: outside.url.appending(path: "outside.sh").path)
    }
}

@Test func refreshIsNonRecursiveAndReturnsOnlyOpaqueIDs() throws {
    let directory = TestDirectory()
    directory.executable("hello.sh", "#!/bin/sh\n# prism:name=Hello world\n# prism:description=Print a greeting\n# prism:keywords=greet, demo\nprintf hello\n")
    try FileManager.default.createDirectory(at: directory.url.appending(path: "nested"), withIntermediateDirectories: true)
    directory.executable("nested/hidden.sh", "#!/bin/sh\nprintf hidden\n")

    let registry = ScriptRegistry(inMemory: ())
    let result = try registry.refresh(directories: [directory.path])
    #expect(result.commands.count == 1)
    #expect(result.commands[0].title == "Hello world")
    #expect(result.commands[0].description == "Print a greeting")
    #expect(result.commands[0].keywords == ["greet", "demo"])
    #expect(result.commands[0].id.hasPrefix("sc_"))
    #expect(!result.commands[0].id.contains("hello"))
}

@Test func refreshRejectsSymlinksAndNonExecutableFiles() throws {
    let directory = TestDirectory()
    let executable = directory.executable("allowed.sh", "#!/bin/sh\nexit 0\n")
    directory.file("not-executable.sh", "#!/bin/sh\nexit 0\n")
    try FileManager.default.createSymbolicLink(atPath: directory.url.appending(path: "alias.sh").path, withDestinationPath: executable.path)

    let registry = ScriptRegistry(inMemory: ())
    let result = try registry.refresh(directories: [directory.path])
    #expect(result.commands.count == 1)
    #expect(result.skippedEntries == 2)
}

@Test func refreshSortsByTitleAndFallsBackToTheFileName() throws {
    let directory = TestDirectory()
    directory.executable("zeta.sh", "#!/bin/sh\n# @raycast.title alpha\n")
    directory.executable("Beta Tool.py", "#!/usr/bin/env python3\n")
    directory.executable("unsupported.txt", "#!/bin/sh\n")
    let registry = ScriptRegistry(inMemory: ())
    let result = try registry.refresh(directories: [directory.path, directory.path])
    #expect(result.commands.map(\.title) == ["alpha", "Beta Tool"])
    #expect(result.scannedDirectories == 1)
    #expect(result.skippedEntries == 1)
}

@Test func executionRequiresACurrentRegisteredPathAndBoundsOutput() throws {
    let (directory, registry, registered) = try fixture("#!/bin/sh\nprintf 'hello'\nprintf 'problem' >&2\n")
    let result = try ScriptExecutor.execute(registered, arguments: [], run: ScriptRun(scriptID: registered.summary.id), timeout: generousTimeout)
    #expect(result.succeeded)
    #expect(result.stdout == "hello")
    #expect(result.stderr == "problem")
    #expect(result.exitCode == 0)

    try FileManager.default.removeItem(at: directory.url.appending(path: "fixture.sh"))
    #expect(throws: ScriptError.self) { try ScriptExecutor.execute(registered, arguments: [], run: ScriptRun(scriptID: ""), timeout: generousTimeout) }
    #expect(throws: ScriptError.self) { try registry.registered("sc_ffffffffffffffff") }
}

@Test func parsesArgumentsAndPassesLiteralValuesWithoutShellInterpolation() throws {
    let (directory, _, script) = try fixture("""
    #!/bin/sh
    # @raycast.argument1 {"type":"text","placeholder":"Target"}
    # prism:argument2={"type":"text","placeholder":"Optional","optional":true}
    printf '%s|%s|%s' "$#" "$1" "$2"

    """)
    #expect(script.summary.arguments.count == 2)
    #expect(throws: ScriptError.self) { try ScriptArgumentValidation.validate(script.summary, []) }
    #expect(throws: ScriptError.self) { try ScriptArgumentValidation.validate(script.summary, ["x", "y", "z"]) }
    #expect(throws: ScriptError.self) { try ScriptArgumentValidation.validate(script.summary, ["x\0"]) }
    let args = try ScriptArgumentValidation.validate(script.summary, ["hello; $(echo injected)"])
    let result = try ScriptExecutor.execute(script, arguments: args, run: ScriptRun(scriptID: ""), timeout: generousTimeout)
    #expect(result.stdout == "2|hello; $(echo injected)|")
    withExtendedLifetime(directory) {}
}

@Test func validatesDropdownEncodingAndRejectsMalformedOrGappedMetadata() throws {
    let (_, _, script) = try fixture("""
    #!/bin/sh
    # prism:argument1={"type":"dropdown","placeholder":"Choice","percentEncoded":true,"data":[{"title":"Korean","value":"한 글&"}]}
    exit 0

    """)
    #expect(throws: ScriptError.self) { try ScriptArgumentValidation.validate(script.summary, ["unlisted"]) }
    #expect(try ScriptArgumentValidation.validate(script.summary, ["한 글&"]) == ["%ED%95%9C%20%EA%B8%80%26"])
    for metadata in [
        #"# prism:argument1={bad}"#,
        #"# prism:argument2={"type":"text","placeholder":"Gap"}"#,
        #"# prism:argument1={"type":"file","placeholder":"Unsupported"}"#,
    ] {
        let (_, _, script) = try fixture("#!/bin/sh\n\(metadata)\nexit 0\n")
        #expect(script.summary.argumentError != nil)
        #expect(throws: ScriptError.self) { try ScriptArgumentValidation.validate(script.summary, []) }
    }
}

@Test(arguments: [true, false])
func cancellationAndTimeoutKillDescendantsAndKeepOutput(cancel: Bool) throws {
    // The background child records its PID so the test can check it died instead of sleeping past its timer.
    let (directory, _, script) = try fixture("#!/bin/sh\nprintf started\nprintf problem >&2\n(sleep 30; printf leaked > escaped) &\necho $! > child.pid\nwait\n")
    let run = ScriptRun(scriptID: script.summary.id)
    nonisolated(unsafe) var result: ScriptCommandRunResult?
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        result = try? ScriptExecutor.execute(script, arguments: [], run: run, timeout: cancel ? generousTimeout : 5)
        done.signal()
    }
    if cancel {
        waitUntil(seconds: generousTimeout) { !run.stdout.isEmpty && directory.exists("child.pid") }
        run.requestCancel()
    }
    done.wait()
    let finished = try #require(result)
    #expect(finished.cancelled == cancel)
    #expect(finished.timedOut == !cancel)
    #expect(!finished.succeeded)
    #expect(finished.stdout == "started")
    #expect(finished.stderr == "problem")
    #expect(!finished.stdoutTruncated && !finished.stderrTruncated)
    let pidText = try String(contentsOf: directory.url.appending(path: "child.pid"), encoding: .utf8)
    let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    waitUntil(seconds: generousTimeout) { kill(pid, 0) != 0 }
    #expect(kill(pid, 0) != 0 && errno == ESRCH, "descendant survived termination")
    #expect(!directory.exists("escaped"))
}

@Test func outputHeldOpenByAnEscapedDescendantIsBoundedAndMarkedTruncated() throws {
    // perl leaves the process group with setsid, so killing the group cannot close the pipes it inherited.
    let (directory, _, script) = try fixture("""
    #!/bin/sh
    printf before
    perl -MPOSIX -e 'POSIX::setsid(); open(F, ">ready"); close F; sleep 6' &
    while [ ! -e ready ]; do sleep 0.05; done
    exit 0

    """)
    let started = Date()
    let result = try ScriptExecutor.execute(script, arguments: [], run: ScriptRun(scriptID: ""), timeout: generousTimeout)
    #expect(result.succeeded)
    #expect(result.stdout == "before")
    #expect(result.stdoutTruncated, "a pipe still open after the drain limit is reported as truncated")
    #expect(Date().timeIntervalSince(started) < 6, "the drain is bounded rather than waiting for the descendant")
    withExtendedLifetime(directory) {}
}

@Test func outputWrittenRightBeforeTheProcessExitsIsComplete() throws {
    // Fills more than one pipe buffer and exits at once; everything must be read before the result is built.
    let (directory, _, script) = try fixture("#!/bin/sh\nhead -c 60000 /dev/zero | tr '\\0' a\nprintf end\n")
    for _ in 0..<5 {
        let result = try ScriptExecutor.execute(script, arguments: [], run: ScriptRun(scriptID: ""), timeout: generousTimeout)
        #expect(result.stdout.utf8.count == 60_003)
        #expect(result.stdout.hasSuffix("end"))
        #expect(!result.stdoutTruncated)
    }
    withExtendedLifetime(directory) {}
}

@Test func drainsAndBoundsBothStreamsAndReportsNonzeroExit() throws {
    let (directory, _, script) = try fixture("#!/bin/sh\nhead -c 100000 /dev/zero\nhead -c 100000 /dev/zero >&2\nexit 7\n")
    let result = try ScriptExecutor.execute(script, arguments: [], run: ScriptRun(scriptID: ""), timeout: generousTimeout)
    #expect(result.exitCode == 7)
    #expect(!result.succeeded)
    #expect(result.stdout.utf8.count == ScriptLimits.maxCaptureBytes)
    #expect(result.stderr.utf8.count == ScriptLimits.maxCaptureBytes)
    #expect(result.stdoutTruncated && result.stderrTruncated)
    withExtendedLifetime(directory) {}
}

@Test func runRegistryLimitsConcurrencyAndPublishesCancellation() throws {
    let directory = TestDirectory()
    for index in 0..<5 { directory.executable("wait\(index).sh", "#!/bin/sh\nprintf ready\nsleep 8\n") }
    let registry = ScriptRegistry(inMemory: ())
    let refresh = try registry.refresh(directories: [directory.path])
    #expect(try registry.listRuns().isEmpty, "discovery must never execute")
    #expect(throws: ScriptError.self) { try registry.resolveRun("../../wait.sh") }
    let runs = try refresh.commands.prefix(4).map { try registry.start(scriptID: $0.id, arguments: []) }
    #expect(throws: ScriptError.self) { try registry.start(scriptID: refresh.commands[4].id, arguments: []) }
    for snapshot in runs { _ = try registry.cancel(snapshot.runId) }
    for snapshot in runs {
        let run = try registry.resolveRun(snapshot.runId)
        waitUntil(seconds: generousTimeout) { run.isFinished }
        let finished = run.snapshot()
        #expect(finished.state == .cancelled)
        #expect(finished.result?.cancelled == true)
    }
}

@Test func runListingReattachesAfterRefreshWithoutExecutionOrArguments() throws {
    let directory = TestDirectory()
    directory.executable("recover.sh", "#!/bin/sh\nprintf ready\nsleep 8\n")
    let registry = ScriptRegistry(inMemory: ())
    let first = try registry.refresh(directories: [directory.path])
    let scriptID = first.commands[0].id
    let snapshot = try registry.start(scriptID: scriptID, arguments: [])
    #expect(throws: ScriptError.self) { try registry.start(scriptID: scriptID, arguments: []) }
    let refreshed = try registry.refresh(directories: [directory.path])
    #expect(refreshed.commands[0].id == scriptID)
    let listed = try registry.listRuns()
    #expect(listed.count == 1)
    #expect(listed[0].runId == snapshot.runId)
    #expect(listed[0].scriptId == scriptID)
    let serialized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(listed[0])) as! [String: Any]
    #expect(serialized["args"] == nil)
    #expect(serialized["path"] == nil)
    _ = try registry.cancel(snapshot.runId)
    let run = try registry.resolveRun(snapshot.runId)
    waitUntil(seconds: generousTimeout) { run.isFinished }
    #expect(try registry.listRuns()[0].state == .cancelled)
    #expect(registry.nextRunSequence == 1, "reattachment must never execute again")
}

@Test func restartMarksInflightInterruptedPreservesOutputAndNeverExecutes() throws {
    let directory = TestDirectory()
    let url = directory.url.appending(path: "history.json")
    let registry = ScriptRegistry()
    try registry.initialize(historyURL: url)
    let run = historyRun(registry, 7)
    run.stdout.append(Data("checkpoint output".utf8))
    run.stderr.append(Data("warning".utf8))
    try run.checkpoint()

    let restarted = ScriptRegistry()
    try restarted.initialize(historyURL: url)
    let snapshots = try restarted.listRuns()
    #expect(snapshots.count == 1)
    #expect(snapshots[0].state == .interrupted)
    #expect(snapshots[0].stdout == "checkpoint output")
    #expect(snapshots[0].stderr == "warning")
    #expect(snapshots[0].result == nil)
    #expect(snapshots[0].startedAtMs == 1_000)
    #expect(restarted.nextRunSequence == 7)
    #expect(restarted.commands.isEmpty)
    #expect(restarted.activeRunCount == 0)
    #expect(try readHistory(url).runs[0].state == .interrupted, "recovery itself is durable")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}

@Test func identitiesSurviveRestartAndChangedDiscoveryOrder() throws {
    let directory = TestDirectory()
    directory.executable("zebra.sh", "#!/bin/sh\nexit 0\n")
    let historyDirectory = TestDirectory()
    let url = historyDirectory.url.appending(path: "history.json")
    let registry = ScriptRegistry()
    try registry.initialize(historyURL: url)
    let originalID = try registry.refresh(directories: [directory.path]).commands[0].id
    directory.executable("aardvark.sh", "#!/bin/sh\nexit 0\n")
    let restarted = ScriptRegistry()
    try restarted.initialize(historyURL: url)
    let fresh = try restarted.refresh(directories: [directory.path])
    #expect(fresh.commands[1].id == originalID)
    #expect(fresh.commands[0].id != originalID)
    #expect(try restarted.listRuns().isEmpty)
}

@Test func timeoutMetadataHasSafeDefaultAndRejectsOutOfRangeValues() throws {
    for (value, expected) in [("1", 1), ("3600", 3600), ("0", nil), ("3601", nil), ("-1", nil), ("1.5", nil), ("never", nil)] as [(String, Int?)] {
        let (_, _, script) = try fixture("#!/bin/sh\n# prism:timeout=\(value)\nexit 0\n")
        #expect((script.summary.argumentError == nil) == (expected != nil), "\(value)")
        if let expected { #expect(script.summary.timeoutSeconds == expected) }
    }
    let (_, _, script) = try fixture("#!/bin/sh\nexit 0\n")
    #expect(script.summary.timeoutSeconds == ScriptLimits.defaultTimeoutSeconds)
}

@Test func configuredTimeoutIsEnforcedAndTerminalResultIsDurable() throws {
    let directory = TestDirectory()
    directory.executable("timeout.sh", "#!/bin/sh\n# prism:timeout=5\nprintf before-timeout\nsleep 30\n")
    let historyDirectory = TestDirectory()
    let url = historyDirectory.url.appending(path: "history.json")
    let registry = ScriptRegistry()
    try registry.initialize(historyURL: url)
    let scripts = try registry.refresh(directories: [directory.path])
    let initial = try registry.start(scriptID: scripts.commands[0].id, arguments: [])
    let run = try registry.resolveRun(initial.runId)
    waitUntil(seconds: generousTimeout) { run.snapshot().state != .running }
    let snapshot = run.snapshot()
    #expect(snapshot.state == .timedOut)
    #expect(snapshot.persistenceError == nil)
    #expect(snapshot.timeoutSeconds == 5)
    #expect(snapshot.result?.timedOut == true)
    #expect(snapshot.stdout == "before-timeout")

    let restarted = ScriptRegistry()
    try restarted.initialize(historyURL: url)
    let restored = try restarted.listRuns()
    #expect(restored[0].state == .timedOut)
    #expect(restored[0].stdout == "before-timeout")
    #expect(restored[0].result?.stdout == "before-timeout")
}

@Test func passwordArgumentsAndEchoedOutputAreNeverPersisted() throws {
    let directory = TestDirectory()
    directory.executable("secret.sh", "#!/bin/sh\n# prism:argument1={\"type\":\"password\",\"placeholder\":\"Secret\",\"percentEncoded\":true}\nprintf '%s' \"$1\"\nprintf '%s' \"$1\" >&2\n")
    let historyDirectory = TestDirectory()
    let url = historyDirectory.url.appending(path: "history.json")
    let registry = ScriptRegistry()
    try registry.initialize(historyURL: url)
    let scripts = try registry.refresh(directories: [directory.path])
    let initial = try registry.start(scriptID: scripts.commands[0].id, arguments: ["secret value!"])
    let run = try registry.resolveRun(initial.runId)
    waitUntil(seconds: generousTimeout) { run.snapshot().state != .running }
    #expect(run.snapshot().stdout == "secret%20value!")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("secret value!"))
    #expect(!text.contains("secret%20value!"))
    #expect(!text.contains("\"args\""))

    let restarted = ScriptRegistry()
    try restarted.initialize(historyURL: url)
    let snapshots = try restarted.listRuns()
    #expect(snapshots[0].state == .success)
    #expect(snapshots[0].outputWithheld)
    #expect(snapshots[0].stdout.isEmpty && snapshots[0].stderr.isEmpty)
    #expect(snapshots[0].result?.stdout.isEmpty == true)
}

@Test func retentionKeepsActiveRunsAndBoundsSavedStreams() throws {
    let directory = TestDirectory()
    let url = directory.url.appending(path: "history.json")
    let registry = ScriptRegistry()
    try registry.initialize(historyURL: url)
    let active = historyRun(registry, 1)
    try active.checkpoint()
    for sequence in 2...40 {
        let run = historyRun(registry, UInt64(sequence))
        run.stdout.append(Data(repeating: UInt8(ascii: "x"), count: ScriptLimits.maxCaptureBytes + 99))
        run.complete(.failure(ScriptError("fixture terminal failure")))
    }
    let saved = try readHistory(url)
    #expect(saved.runs.count == ScriptLimits.maxRuns)
    #expect(saved.runs[0].state == .running)
    #expect(saved.runs[0].runId == active.runID)
    #expect(saved.runs.dropFirst().allSatisfy { $0.stdout.utf8.count == ScriptLimits.maxCaptureBytes && $0.stdoutTruncated })
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    #expect(size < ScriptLimits.maxHistoryFileBytes)
}

@Test func initialCheckpointFailureNeverLaunchesAndSaveRetryNeverExecutes() throws {
    let directory = TestDirectory()
    directory.executable("marker.sh", "#!/bin/sh\nprintf ran > executed\n")
    let historyDirectory = TestDirectory()
    let url = historyDirectory.url.appending(path: "history.json")
    let registry = ScriptRegistry()
    try registry.initialize(historyURL: url)
    let scripts = try registry.refresh(directories: [directory.path])
    let blocker = URL(filePath: url.path + ".tmp")
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
    #expect(throws: ScriptError.self) { try registry.start(scriptID: scripts.commands[0].id, arguments: []) }
    #expect(!directory.exists("executed"))
    #expect(try registry.listRuns().isEmpty)
    let run = historyRun(registry, 2)
    run.complete(.failure(ScriptError("fixture failure")))
    #expect(run.snapshot().persistenceError != nil)
    try FileManager.default.removeItem(at: blocker)
    run.saveProgress()
    #expect(run.snapshot().persistenceError == nil)
    #expect(!directory.exists("executed"))
    let saved = try readHistory(url)
    #expect(saved.runs.count == 1)
    #expect(saved.runs[0].state == .failure)
}

@Test func corruptOrOversizedHistoryIsPreservedAndInitializationFails() throws {
    let directory = TestDirectory()
    let url = directory.url.appending(path: "history.json")
    try Data("{broken".utf8).write(to: url)
    let registry = ScriptRegistry()
    #expect(throws: ScriptError.self) { try registry.initialize(historyURL: url) }
    #expect(try Data(contentsOf: url) == Data("{broken".utf8))
    #expect(!registry.isHistoryAvailable)
    #expect(throws: ScriptError.self) { try registry.listRuns() }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(ScriptLimits.maxHistoryFileBytes + 1))
    try handle.close()
    #expect(throws: ScriptError.self) { try registry.initialize(historyURL: url) }
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int) == ScriptLimits.maxHistoryFileBytes + 1)
}

@Test func uninitializedRegistryFailsClosed() throws {
    let directory = TestDirectory()
    directory.executable("a.sh", "#!/bin/sh\nexit 0\n")
    let registry = ScriptRegistry()
    #expect(throws: ScriptError("Script history is unavailable. Restart Prism to retry initialization.")) {
        try registry.refresh(directories: [directory.path])
    }
}

@Test func boundedOutputKeepsOnlyTheConfiguredPrefix() {
    let output = BoundedOutput()
    output.append(Data(repeating: UInt8(ascii: "x"), count: ScriptLimits.maxCaptureBytes + 17))
    let (captured, truncated) = output.snapshot()
    #expect(captured.utf8.count == ScriptLimits.maxCaptureBytes)
    #expect(truncated)
}

@Test func historyFileUsesTheTauriKeys() throws {
    let file = ScriptHistoryFile(version: 1, nextScriptId: 2, nextRunId: 3, identities: [ScriptIdentity(path: "/a/b.sh", root: "/a", id: "sc_0000000000000002")],
                                 runs: [ScriptRunSnapshot(startedAtMs: 5, timeoutSeconds: 10, runId: "sr_0000000000000003", scriptId: "sc_0000000000000002", state: .timedOut)])
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
    #expect(Set(object.keys) == ["version", "next_script_id", "next_run_id", "identities", "runs"])
    let run = (object["runs"] as! [[String: Any]])[0]
    #expect(Set(run.keys) == ["startedAtMs", "timeoutSeconds", "outputWithheld", "persistenceError", "runId", "scriptId", "state", "result", "error", "stdout", "stderr", "stdoutTruncated", "stderrTruncated"])
    #expect(run["state"] as? String == "timedOut")
    #expect(run["result"] is NSNull)
    // The Tauri file as serde writes it decodes unchanged.
    let tauri = #"{"version":1,"next_script_id":0,"next_run_id":0,"identities":[],"runs":[]}"#
    #expect(try JSONDecoder().decode(ScriptHistoryFile.self, from: Data(tauri.utf8)) == ScriptHistoryFile())
}

@Test func workingDirectoryDefaultsToTheScriptFolderAndHonorsCurrentDirectoryPath() throws {
    let directory = TestDirectory()
    try FileManager.default.createDirectory(at: directory.url.appending(path: "work"), withIntermediateDirectories: true)
    directory.executable("pwd.sh", "#!/bin/sh\npwd\n")
    directory.executable("sub.sh", "#!/bin/sh\n# @raycast.currentDirectoryPath work\npwd\n")
    let registry = ScriptRegistry(inMemory: ())
    let commands = try registry.refresh(directories: [directory.path]).commands
    let pwd = try registry.registered(commands.first { $0.title == "pwd" }!.id)
    let sub = try registry.registered(commands.first { $0.title == "sub" }!.id)
    #expect(try ScriptExecutor.execute(pwd, arguments: [], run: ScriptRun(scriptID: ""), timeout: generousTimeout).stdout == directory.path + "\n")
    #expect(try ScriptExecutor.execute(sub, arguments: [], run: ScriptRun(scriptID: ""), timeout: generousTimeout).stdout == directory.path + "/work\n")
}
