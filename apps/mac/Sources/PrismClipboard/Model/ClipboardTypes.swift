import Foundation

public enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text, image, files
}

/// One history row as the list shows it. Search never loads image bytes or file URL payloads, and `text`
/// is a bounded preview (500 characters) of the stored label.
public struct ClipboardEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var text: String
    public var capturedAtMs: Int64
    public var pinned: Bool
    public var kind: ClipboardKind
    public var mimeType: String?
    public var byteSize: Int
    public var width: Int?
    public var height: Int?
    public var fileCount: Int

    /// `nil` means unknown: file references are only checked when they are copied or pasted.
    public var available: Bool? { kind == .files ? nil : true }

    public var capturedAt: Date { Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1000) }
}

/// Original clipboard content, read only for the selected entry or an explicit copy or paste.
public enum ClipboardPayload: Equatable, Sendable {
    case text(String)
    case image(Data, mimeType: String, width: Int, height: Int)
    /// `file://` URL strings, one per pasteboard item.
    case files([String])
}

public enum ClipboardPrimaryAction: String, Codable, Sendable, CaseIterable {
    case paste, copy
}

public struct ExcludedApplication: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
}

/// Stored as JSON in `clipboard_preferences` with the Tauri app's camelCase keys. Missing keys use defaults.
public struct ClipboardPreferences: Codable, Equatable, Sendable {
    public var primaryAction: ClipboardPrimaryAction = .paste
    public var pausedUntilMs: Int64 = 0
    public var excludedApplications: [ExcludedApplication] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryAction = try container.decodeIfPresent(ClipboardPrimaryAction.self, forKey: .primaryAction) ?? .paste
        pausedUntilMs = try container.decodeIfPresent(Int64.self, forKey: .pausedUntilMs) ?? 0
        excludedApplications = try container.decodeIfPresent([ExcludedApplication].self, forKey: .excludedApplications) ?? []
    }

    func isCapturing(at time: Int64) -> Bool { pausedUntilMs <= time }

    /// With any exclusion configured, an unknown frontmost app is treated as excluded.
    func excludes(_ bundleIdentifier: String?) -> Bool {
        guard !excludedApplications.isEmpty else { return false }
        guard let bundleIdentifier else { return true }
        return excludedApplications.contains { $0.id == bundleIdentifier }
    }
}

public struct ClipboardSettingsState: Equatable, Sendable {
    public var enabled = false
    public var retentionDays = 30
    public var entryCount = 0
    public var pinnedCount = 0
    public var capacity = ClipboardLimits.capacity
    public var persistenceError: String?
    public var captureNotice: String?
    public var preferences = ClipboardPreferences()

    public var isPaused: Bool { preferences.pausedUntilMs > ClipboardClock.nowMs() }
}

/// An English message from the Rust specification. Shown through `localizedDescription`, which looks it up
/// in this module's Korean strings.
public struct ClipboardError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { ClipboardText.localize(message) }

    static let disabled = ClipboardError("Clipboard history is disabled.")
    static let storage = ClipboardError("Clipboard history could not be saved. Check available disk space and storage permissions, then retry.")
    static let unavailable = ClipboardError("Clipboard history storage is unavailable. Restart Prism to retry.")
    static let missingEntry = ClipboardError("That clipboard history entry no longer exists.")
    static let changed = ClipboardError("Clipboard history changed. Select the entry again.")
    static let unsupported = ClipboardError("This clipboard format is unsupported. Copy PNG, JPEG, WebP, plain text, or local files.")
    static let referenceLimit = ClipboardError("File references exceed the clipboard size limit.")
    static let invalidReference = ClipboardError("Invalid file reference.")
    static let localReferencesOnly = ClipboardError("Only local file references are supported.")
    static let missingFile = ClipboardError("A referenced file is missing or unavailable. Restore it before copying or pasting.")
    static let pinnedStorageFull = ClipboardError("Pinned history fills the storage limit. Unpin or delete entries to capture more.")
}

public enum ClipboardLimits {
    public static let capacity = 1000
    static let maxTextBytes = 128 * 1024
    static let maxImageBytes = 8 * 1024 * 1024
    static let maxTIFFInputBytes = 64 * 1024 * 1024
    static let maxImageDimension = 8192
    static let maxImagePixels = 16_000_000
    static let maxFileReferences = 64
    static let maxReferenceBytes = 64 * 1024
    static let maxStoredBytes = 128 * 1024 * 1024
    static let searchPreviewCharacters = 500
    static let retentionChoices = [1, 7, 30, 90]
    static let pauseChoices = [0, 5, 15, 60]
    static let maxExcludedApplications = 128
    static let dayMs: Int64 = 86_400_000
}

public enum ClipboardClock {
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

enum ClipboardText {
    static func localize(_ message: String) -> String {
        Bundle.module.localizedString(forKey: message, value: message, table: nil)
    }
}
