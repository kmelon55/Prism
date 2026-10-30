import Foundation

/// Limits shared with the Tauri implementation (`script_commands.rs`).
enum ScriptLimits {
    static let maxDirectories = 32
    static let maxEntries = 2_048
    static let maxMetadataBytes = 8 * 1_024
    static let maxMetadataLines = 64
    static let maxCaptureBytes = 64 * 1_024
    static let defaultTimeoutSeconds = 10
    static let maxTimeoutSeconds = 3_600
    static let maxRuns = 32
    static let maxActiveRuns = 4
    static let maxHistoryFileBytes = 64 * 1_024 * 1_024
    static let maxArgumentBytes = 8_192
    static let minimumRefreshSeconds = 10
}

public struct ScriptArgumentOption: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var value: String
}

/// One `argumentN` entry. Decodes the same JSON the Rust parser accepts: `type` and `placeholder` are required,
/// `optional`, `percentEncoded` and `data` default to false and empty, and unknown keys are ignored.
public struct ScriptArgument: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case text, password, dropdown }

    public var type: String
    public var placeholder: String
    public var optional: Bool
    public var percentEncoded: Bool
    public var data: [ScriptArgumentOption]

    public init(type: String, placeholder: String, optional: Bool = false, percentEncoded: Bool = false, data: [ScriptArgumentOption] = []) {
        self.type = type
        self.placeholder = placeholder
        self.optional = optional
        self.percentEncoded = percentEncoded
        self.data = data
    }

    public var kind: Kind { Kind(rawValue: type) ?? .text }

    enum CodingKeys: String, CodingKey { case type, placeholder, optional, percentEncoded, data }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        placeholder = try container.decode(String.self, forKey: .placeholder)
        optional = try container.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        percentEncoded = try container.decodeIfPresent(Bool.self, forKey: .percentEncoded) ?? false
        data = try container.decodeIfPresent([ScriptArgumentOption].self, forKey: .data) ?? []
    }
}

/// Raycast output modes. Scripts without a mode keep the Tauri behavior: a foreground output screen.
public enum ScriptOutputMode: String, Sendable, CaseIterable {
    case fullOutput, compact, silent, inline
}

public struct ScriptMetadata: Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var keywords: [String] = []
    public var arguments: [ScriptArgument] = []
    public var argumentError: String?
    public var timeoutSeconds: Int?

    // Raycast metadata that the Tauri parser ignored. None of these block execution when malformed.
    public var schemaVersion: Int?
    public var mode: ScriptOutputMode?
    public var packageName: String?
    public var icon: String?
    public var iconDark: String?
    public var needsConfirmation = false
    public var refreshSeconds: Int?
    public var currentDirectoryPath: String?
    public var author: String?

    public init() {}
}

public enum ScriptMetadataParser {
    /// Reads at most the first 8 KiB of the file, like `read_script_metadata`. Unreadable files have no metadata.
    public static func read(url: URL) -> ScriptMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ScriptMetadata() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ScriptLimits.maxMetadataBytes) else { return ScriptMetadata() }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Accepts `# prism:key=value` and `# @raycast.key value`. Raycast's `// @raycast.` (JavaScript, Swift) and
    /// `-- @raycast.` (AppleScript) comment styles are accepted too.
    public static func parse(_ text: String) -> ScriptMetadata {
        var metadata = ScriptMetadata()
        var arguments: [Int: ScriptArgument] = [:]
        for rawLine in lines(text).prefix(ScriptLimits.maxMetadataLines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (rawKey, rawValue) = pair(line) else { continue }
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("argument") {
                let index = Int(key.dropFirst("argument".count)).flatMap { (1...3).contains($0) ? $0 : nil }
                let argument = try? JSONDecoder().decode(ScriptArgument.self, from: Data(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                if let index, let argument, isValidArgument(argument) {
                    if arguments.updateValue(argument, forKey: index) != nil {
                        metadata.argumentError = "Duplicate script argument metadata."
                    }
                } else {
                    metadata.argumentError = "Invalid script argument metadata."
                }
                continue
            }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "name", "title": metadata.name = validatedValue(value, maximum: 120)
            case "description": metadata.description = validatedValue(value, maximum: 240)
            case "timeout":
                if let seconds = strictUnsigned(value), (1...ScriptLimits.maxTimeoutSeconds).contains(seconds) {
                    metadata.timeoutSeconds = seconds
                } else {
                    metadata.argumentError = "Script timeout must be an integer between 1 and \(ScriptLimits.maxTimeoutSeconds) seconds."
                }
            case "keywords":
                metadata.keywords = Array(value.split(separator: ",", omittingEmptySubsequences: false)
                    .compactMap { validatedValue(String($0), maximum: 40) }
                    .prefix(12))
            case "schemaVersion": metadata.schemaVersion = strictUnsigned(value)
            case "mode": metadata.mode = ScriptOutputMode(rawValue: value)
            case "packageName": metadata.packageName = validatedValue(value, maximum: 120)
            case "icon": metadata.icon = validatedValue(value, maximum: 1_024)
            case "iconDark": metadata.iconDark = validatedValue(value, maximum: 1_024)
            case "needsConfirmation": metadata.needsConfirmation = value.lowercased() == "true"
            case "refreshTime": metadata.refreshSeconds = refreshInterval(value)
            case "currentDirectoryPath": metadata.currentDirectoryPath = validatedValue(value, maximum: 4_096)
            case "author": metadata.author = validatedValue(value, maximum: 120)
            default: break
            }
        }
        for (expected, index) in arguments.keys.sorted().enumerated() {
            if index != expected + 1 {
                metadata.argumentError = "Script arguments must be numbered consecutively from 1."
            }
            metadata.arguments.append(arguments[index]!)
        }
        return metadata
    }

    /// Raycast refresh intervals such as `10s`, `5m`, `1h` or `1d`. Shorter than 10 seconds is rejected.
    static func refreshInterval(_ value: String) -> Int? {
        guard let unit = value.last, let amount = strictUnsigned(String(value.dropLast())), amount > 0 else { return nil }
        let multiplier: Int
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: return nil
        }
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        return !overflow && seconds >= ScriptLimits.minimumRefreshSeconds ? seconds : nil
    }

    private static let raycastPrefixes = ["# @raycast.", "// @raycast.", "-- @raycast."]

    private static func pair(_ line: String) -> (Substring, Substring)? {
        if line.hasPrefix("# prism:") {
            let rest = line.dropFirst("# prism:".count)
            guard let separator = rest.firstIndex(of: "=") else { return nil }
            return (rest[..<separator], rest[rest.index(after: separator)...])
        }
        for prefix in raycastPrefixes where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let separator = rest.firstIndex(of: " ") else { return nil }
            return (rest[..<separator], rest[rest.index(after: separator)...])
        }
        return nil
    }

    /// `str::lines`: splits on `\n` and drops one trailing `\r` from each line.
    private static func lines(_ text: String) -> [Substring] {
        // "\r\n" is one Character in Swift, so split on both forms.
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// `u64::from_str`: ASCII digits with an optional leading `+`.
    static func strictUnsigned(_ value: String) -> Int? {
        let digits = value.hasPrefix("+") ? value.dropFirst() : Substring(value)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    static func isValidArgument(_ argument: ScriptArgument) -> Bool {
        ["text", "password", "dropdown"].contains(argument.type)
            && validatedValue(argument.placeholder, maximum: 120) != nil
            && argument.data.count <= 100
            && (argument.type != "dropdown" || !argument.data.isEmpty)
            && argument.data.allSatisfy { option in
                validatedValue(option.title, maximum: 120) != nil
                    && !option.value.isEmpty
                    && option.value.utf8.count <= ScriptLimits.maxArgumentBytes
                    && !option.value.contains("\0")
            }
    }

    static func validatedValue(_ value: String, maximum: Int) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= maximum, !value.unicodeScalars.contains(where: isControl) else { return nil }
        return value
    }

    static func cleanFallbackTitle(_ value: String) -> String {
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.map { isControl($0) ? " " : $0 }))
        return String(String.UnicodeScalarView(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(120)))
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}

public enum ScriptArgumentValidation {
    /// `validate_arguments`: every declared argument gets a positional slot, required values must be present,
    /// dropdown values must be listed, and percent-encoded arguments are encoded here.
    public static func validate(_ summary: ScriptCommandSummary, _ args: [String]) throws(ScriptError) -> [String] {
        if let error = summary.argumentError { throw ScriptError(error) }
        if args.count > summary.arguments.count { throw ScriptError("Too many script arguments.") }
        return try summary.arguments.enumerated().map { (index, argument) throws(ScriptError) -> String in
            let value = index < args.count ? args[index] : ""
            if value.utf8.count > ScriptLimits.maxArgumentBytes || value.contains("\0") {
                throw ScriptError("Argument \(index + 1) is invalid or too long.")
            }
            if !argument.optional && value.isEmpty { throw ScriptError("Argument \(index + 1) is required.") }
            if argument.type == "dropdown", !(argument.optional && value.isEmpty), !argument.data.contains(where: { $0.value == value }) {
                throw ScriptError("Argument \(index + 1) must be one of the listed choices.")
            }
            return argument.percentEncoded ? percentEncode(value) : value
        }
    }

    public static func percentEncode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            let unreserved = (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || Array("-_.!~*'()".utf8).contains(byte)
            if unreserved {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}

/// A product error. `message` is the English text the Tauri app uses (and stores in history); `localizedMessage`
/// translates it for display.
public struct ScriptError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { ScriptStrings.localize(message) }
}
