import AppKit
import PrismKit

/// A modifier pressed twice. Indexes match the Tauri app's `DoubleControl`… names and native kind numbers.
enum DoubleModifier: UInt32, CaseIterable, Sendable {
    case control = 0, option, shift, command

    var storedName: String {
        switch self {
        case .control: "DoubleControl"
        case .option: "DoubleOption"
        case .shift: "DoubleShift"
        case .command: "DoubleCommand"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    init?(storedName: String) {
        guard let match = Self.allCases.first(where: { $0.storedName.caseInsensitiveCompare(storedName) == .orderedSame }) else { return nil }
        self = match
    }
}

/// The shortcut that starts and finishes a recording, as saved by the shell under the command ID.
enum StartShortcut: Equatable, Sendable {
    case doubleModifier(DoubleModifier)
    case keys(Shortcut)
    /// A stored value this module cannot parse. Kept so the label can still show it.
    case unknown(String)

    init(stored: String) {
        if let modifier = DoubleModifier(storedName: stored) {
            self = .doubleModifier(modifier)
        } else if let shortcut = Shortcut(accelerator: stored) {
            self = .keys(shortcut)
        } else {
            self = .unknown(stored)
        }
    }

    var doubleModifier: DoubleModifier? {
        if case .doubleModifier(let modifier) = self { return modifier }
        return nil
    }

    /// The overlay label, in the Tauri format: `⌃ ⌃`, `⌥ D`, `⇧ ⌘ 1`.
    var label: String {
        switch self {
        case .doubleModifier(let modifier): return "\(modifier.symbol) \(modifier.symbol)"
        case .keys(let shortcut): return Self.spacedLabel(shortcut.accelerator)
        case .unknown(let value): return Self.spacedLabel(value)
        }
    }

    static func spacedLabel(_ accelerator: String) -> String {
        accelerator.split(separator: "+").map { part -> String in
            switch part.lowercased() {
            case "commandorcontrol", "super", "meta", "command", "cmd": "⌘"
            case "control", "ctrl": "⌃"
            case "alt", "option": "⌥"
            case "shift": "⇧"
            case "space": "Space"
            case "enter": "Return"
            case "escape": "Esc"
            case "comma": ","
            case "period": "."
            case "slash": "/"
            default:
                part.hasPrefix("Key") ? String(part.dropFirst(3)) : part.hasPrefix("Digit") ? String(part.dropFirst(5)) : String(part)
            }
        }.joined(separator: " ")
    }
}

/// Read-only view of the shell's `command-shortcuts-v1.json` for the two dictation commands.
struct CommandShortcutsFile: Sendable {
    static let fileName = "command-shortcuts-v1.json"
    static let dictationCommand = "prism:dictation"
    static let promptCommand = "prism:dictation-prompt"

    let url: URL

    private struct Persisted: Decodable {
        let version: Int
        let shortcuts: [String: String]
    }

    func load() -> (dictation: StartShortcut?, prompt: StartShortcut?) {
        guard let data = try? Data(contentsOf: url), let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
              persisted.version == 1 else { return (nil, nil) }
        return (persisted.shortcuts[Self.dictationCommand].map(StartShortcut.init(stored:)),
                persisted.shortcuts[Self.promptCommand].map(StartShortcut.init(stored:)))
    }
}
