import Foundation

/// A discovered command, as `list_script_commands` returns it. The path stays inside the registry.
public struct ScriptCommandSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var keywords: [String]
    public var arguments: [ScriptArgument]
    public var argumentError: String?
    public var timeoutSeconds: Int
    public var mode: ScriptOutputMode
    public var packageName: String?
    public var needsConfirmation: Bool
    public var refreshSeconds: Int?
    /// Emoji, or an absolute image path resolved from the Raycast `icon` metadata.
    public var icon: ScriptIcon?
    public var iconDark: ScriptIcon?

    public var hasPasswordArgument: Bool { arguments.contains { $0.type == "password" } }
}

public enum ScriptIcon: Equatable, Sendable {
    case emoji(String)
    case image(path: String)
}

public struct ScriptCommandRunResult: Codable, Equatable, Sendable {
    public var scriptId: String
    public var succeeded: Bool
    public var timedOut: Bool
    public var cancelled: Bool
    public var exitCode: Int32?
    public var durationMs: UInt64
    public var stdout: String
    public var stderr: String
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case scriptId, succeeded, timedOut, cancelled, exitCode, durationMs, stdout, stderr, stdoutTruncated, stderrTruncated
    }

    // serde writes `null` for `None`; keep the file byte-compatible with the Tauri app.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scriptId, forKey: .scriptId)
        try container.encode(succeeded, forKey: .succeeded)
        try container.encode(timedOut, forKey: .timedOut)
        try container.encode(cancelled, forKey: .cancelled)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(stdoutTruncated, forKey: .stdoutTruncated)
        try container.encode(stderrTruncated, forKey: .stderrTruncated)
    }
}

public enum ScriptRunState: String, Codable, Sendable {
    case running, success, failure, cancelled, timedOut, interrupted

    public var isTerminal: Bool { self != .running }
}

/// `ScriptRunSnapshot` in `script_commands.rs`, stored in `script-runs-v1.json`. Arguments are never part of it.
public struct ScriptRunSnapshot: Codable, Equatable, Sendable {
    public var startedAtMs: UInt64
    public var timeoutSeconds: UInt64
    public var outputWithheld: Bool
    public var persistenceError: String?
    public var runId: String
    public var scriptId: String
    public var state: ScriptRunState
    public var result: ScriptCommandRunResult?
    public var error: String?
    public var stdout: String
    public var stderr: String
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case startedAtMs, timeoutSeconds, outputWithheld, persistenceError, runId, scriptId, state, result, error
        case stdout, stderr, stdoutTruncated, stderrTruncated
    }

    public init(
        startedAtMs: UInt64, timeoutSeconds: UInt64, outputWithheld: Bool = false, persistenceError: String? = nil,
        runId: String, scriptId: String, state: ScriptRunState, result: ScriptCommandRunResult? = nil, error: String? = nil,
        stdout: String = "", stderr: String = "", stdoutTruncated: Bool = false, stderrTruncated: Bool = false
    ) {
        self.startedAtMs = startedAtMs
        self.timeoutSeconds = timeoutSeconds
        self.outputWithheld = outputWithheld
        self.persistenceError = persistenceError
        self.runId = runId
        self.scriptId = scriptId
        self.state = state
        self.result = result
        self.error = error
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAtMs = try container.decode(UInt64.self, forKey: .startedAtMs)
        timeoutSeconds = try container.decode(UInt64.self, forKey: .timeoutSeconds)
        outputWithheld = try container.decode(Bool.self, forKey: .outputWithheld)
        persistenceError = try container.decodeIfPresent(String.self, forKey: .persistenceError)
        runId = try container.decode(String.self, forKey: .runId)
        scriptId = try container.decode(String.self, forKey: .scriptId)
        // Unknown states are rejected by validation rather than by decoding, like the Rust reader.
        let rawState = try container.decode(String.self, forKey: .state)
        guard let state = ScriptRunState(rawValue: rawState) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "Unknown run state")
        }
        self.state = state
        result = try container.decodeIfPresent(ScriptCommandRunResult.self, forKey: .result)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        stdout = try container.decode(String.self, forKey: .stdout)
        stderr = try container.decode(String.self, forKey: .stderr)
        stdoutTruncated = try container.decode(Bool.self, forKey: .stdoutTruncated)
        stderrTruncated = try container.decode(Bool.self, forKey: .stderrTruncated)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startedAtMs, forKey: .startedAtMs)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(outputWithheld, forKey: .outputWithheld)
        try container.encode(persistenceError, forKey: .persistenceError)
        try container.encode(runId, forKey: .runId)
        try container.encode(scriptId, forKey: .scriptId)
        try container.encode(state, forKey: .state)
        try container.encode(result, forKey: .result)
        try container.encode(error, forKey: .error)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(stdoutTruncated, forKey: .stdoutTruncated)
        try container.encode(stderrTruncated, forKey: .stderrTruncated)
    }
}

struct ScriptIdentity: Codable, Equatable, Sendable {
    var path: String
    var root: String
    var id: String
}

/// The `script-runs-v1.json` schema. Keys are snake_case at the top level, exactly as serde writes them.
struct ScriptHistoryFile: Codable, Equatable, Sendable {
    var version: UInt32 = 1
    var nextScriptId: UInt64 = 0
    var nextRunId: UInt64 = 0
    var identities: [ScriptIdentity] = []
    var runs: [ScriptRunSnapshot] = []

    enum CodingKeys: String, CodingKey {
        case version
        case nextScriptId = "next_script_id"
        case nextRunId = "next_run_id"
        case identities, runs
    }
}

/// Where run history lives. Fixture registries in tests use `.memory`; a failed initialization is `.unavailable`
/// so execution fails closed until Prism restarts.
enum ScriptHistoryLocation: Sendable {
    case memory
    case unavailable
    case file(URL)
}

final class ScriptRunHistory: @unchecked Sendable {
    let lock = NSLock()
    var location: ScriptHistoryLocation
    var file = ScriptHistoryFile()

    init(location: ScriptHistoryLocation) {
        self.location = location
    }

    /// Caller holds `lock`.
    func write() throws(ScriptError) {
        switch location {
        case .memory: return
        case .unavailable: throw ScriptError("Script history is unavailable. Restart Prism to retry initialization.")
        case .file(let url): try Self.write(file, to: url)
        }
    }

    static func write(_ history: ScriptHistoryFile, to url: URL) throws(ScriptError) {
        var history = history
        for index in history.runs.indices {
            history.runs[index].result?.stdout = ""
            history.runs[index].result?.stderr = ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(history) else { throw ScriptError("Could not encode script history.") }
        if bytes.count > ScriptLimits.maxHistoryFileBytes { throw ScriptError("Script history exceeded its storage limit.") }
        let temporary = url.path + ".tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ScriptError("Could not save script history: \(String(cString: strerror(errno)))") }
        var failure: String?
        if fchmod(descriptor, 0o600) != 0 { failure = String(cString: strerror(errno)) }
        if failure == nil {
            let written = bytes.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0 { if errno == EINTR { continue }; return false }
                    offset += count
                }
                return true
            }
            if !written || fsync(descriptor) != 0 { failure = String(cString: strerror(errno)) }
        }
        close(descriptor)
        if let failure { throw ScriptError("Could not save script history: \(failure)") }
        guard rename(temporary, url.path) == 0 else {
            throw ScriptError("Could not replace script history: \(String(cString: strerror(errno)))")
        }
        // Flush the rename too, so an acknowledged initial checkpoint precedes execution.
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw ScriptError("Could not flush script history: \(String(cString: strerror(errno)))") }
        defer { close(directory) }
        if fsync(directory) != 0 { throw ScriptError("Could not flush script history: \(String(cString: strerror(errno)))") }
    }
}

enum ScriptIdentifiers {
    static func validateScriptID(_ id: String) throws(ScriptError) {
        guard id.hasPrefix("sc_") else { throw ScriptError("The script command identifier is invalid.") }
        let suffix = id.dropFirst(3)
        guard suffix.count == 16, suffix != "0000000000000000",
              suffix.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw ScriptError("The script command identifier is invalid.")
        }
    }

    static func validateRunID(_ id: String) throws(ScriptError) {
        guard id.hasPrefix("sr_") else { throw ScriptError("Invalid script run identifier.") }
        try validateScriptID("sc_" + id.dropFirst(3))
    }

    static func sequence(_ id: String) -> UInt64 {
        UInt64(id.dropFirst(3), radix: 16) ?? 0
    }

    static func scriptID(_ sequence: UInt64) -> String { "sc_" + hex(sequence) }
    static func runID(_ sequence: UInt64) -> String { "sr_" + hex(sequence) }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}
