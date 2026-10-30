import Foundation
@testable import PrismScripts

/// A temporary directory that removes itself. Fixture scripts only; tests never touch user data.
final class TestDirectory {
    let url: URL
    var path: String { url.path }

    init() {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "prism-script-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Registry roots are canonical (`/private/var/...`), so compare against the canonical path.
        url = URL(filePath: ScriptFileRules.canonicalize(base.path)!)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func executable(_ name: String, _ contents: String) -> URL {
        let file = url.appending(path: name)
        try! contents.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o700)
        return file
    }

    func file(_ name: String, _ contents: String) {
        try! contents.write(to: url.appending(path: name), atomically: true, encoding: .utf8)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url.appending(path: name).path) }
}

func fixture(_ source: String) throws -> (TestDirectory, ScriptRegistry, RegisteredScript) {
    let directory = TestDirectory()
    directory.executable("fixture.sh", source)
    let registry = ScriptRegistry(inMemory: ())
    let refresh = try registry.refresh(directories: [directory.path])
    return (directory, registry, try registry.registered(refresh.commands[0].id))
}

/// An upper bound for waits and for runs that are not about timeouts. Tests wait on conditions, so this only
/// matters when the machine is loaded (the integration run executes every test target at once).
let generousTimeout: TimeInterval = 30

/// Polls until `condition` holds or the deadline passes.
func waitUntil(seconds: Double, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { usleep(5_000) }
}

func historyRun(_ registry: ScriptRegistry, _ sequence: UInt64) -> ScriptRun {
    ScriptRun(scriptID: "sc_0000000000000001", runID: ScriptIdentifiers.runID(sequence), startedAtMs: 1_000, history: registry.history)
}

func readHistory(_ url: URL) throws -> ScriptHistoryFile {
    try JSONDecoder().decode(ScriptHistoryFile.self, from: Data(contentsOf: url))
}
