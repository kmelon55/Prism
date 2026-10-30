// Recording shortcut settings and labels reused from Whisp AppSettings.swift. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit
import Carbon.HIToolbox

/// The four keys that act on a running recording.
enum RecordingAction: CaseIterable, Identifiable, Sendable {
    case cancel, copy, paste, send
    var id: Self { self }

    var title: String {
        switch self {
        case .cancel: String(localized: "Cancel", bundle: .module)
        case .copy: String(localized: "Copy to clipboard only", bundle: .module)
        case .paste: String(localized: "Paste", bundle: .module)
        case .send: String(localized: "Paste and Enter", bundle: .module)
        }
    }

    var subtitle: String {
        switch self {
        case .cancel: String(localized: "Discard the recording without an API request.", bundle: .module)
        case .copy: String(localized: "Copy the result without pasting.", bundle: .module)
        case .paste: String(localized: "Pastes even when the default action is copy.", bundle: .module)
        case .send: String(localized: "Paste, then press Enter to send.", bundle: .module)
        }
    }

    /// Short overlay hint label.
    var hint: String {
        switch self {
        case .cancel: String(localized: "Cancel", bundle: .module)
        case .copy: String(localized: "Copy", bundle: .module)
        case .paste: String(localized: "Paste", bundle: .module)
        case .send: String(localized: "Send", bundle: .module)
        }
    }

    /// Whisp's action number (cancel 1, send 2, paste 3, copy 4), also used in overlay hint IDs.
    var number: UInt32 {
        switch self {
        case .cancel: 1
        case .send: 2
        case .paste: 3
        case .copy: 4
        }
    }

    /// Carbon hot key ID, kept far above PrismKit's `GlobalHotKey` IDs, which count up from 1.
    var hotKeyID: UInt32 { 0x4443_0000 | number }

    static let hintOrder: [RecordingAction] = [.cancel, .copy, .paste, .send]
}

enum RecordingShortcutMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sameAsPrimary, custom, disabled
    var id: String { rawValue }
}

enum RecordingShortcutKind: String, Codable, Hashable, Sendable {
    case keyCombination, singleControl, singleOption, singleShift, singleCommand

    var isSingleModifier: Bool { self != .keyCombination }

    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .singleControl: .control
        case .singleOption: .option
        case .singleShift: .shift
        case .singleCommand: .command
        case .keyCombination: nil
        }
    }

    /// The double-tap modifier index (0 Control, 1 Option, 2 Shift, 3 Command) for the same key.
    var doubleModifier: DoubleModifier? {
        switch self {
        case .singleControl: .control
        case .singleOption: .option
        case .singleShift: .shift
        case .singleCommand: .command
        case .keyCombination: nil
        }
    }

    static func forKeyCode(_ keyCode: UInt16) -> RecordingShortcutKind? {
        switch keyCode {
        case 59, 62: .singleControl
        case 58, 61: .singleOption
        case 56, 60: .singleShift
        case 55, 54: .singleCommand
        default: nil
        }
    }
}

struct RecordingShortcutSetting: Codable, Equatable, Sendable {
    var mode: RecordingShortcutMode
    var kind: RecordingShortcutKind
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    init(mode: RecordingShortcutMode, kind: RecordingShortcutKind = .keyCombination, keyCode: UInt32, modifiers: UInt32, label: String) {
        self.mode = mode
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case mode, kind, keyCode, modifiers, label }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(RecordingShortcutMode.self, forKey: .mode)
        kind = try container.decodeIfPresent(RecordingShortcutKind.self, forKey: .kind) ?? .keyCombination
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        label = try container.decode(String.self, forKey: .label)
    }

    static let cancelDefault = RecordingShortcutSetting(mode: .custom, keyCode: 53, modifiers: 0, label: "Esc")
    static let copyDefault = RecordingShortcutSetting(mode: .disabled, keyCode: 0, modifiers: 0, label: "")
    static let pasteDefault = RecordingShortcutSetting(mode: .sameAsPrimary, keyCode: 0, modifiers: 0, label: "")
    static let pasteAndEnterDefault = RecordingShortcutSetting(mode: .custom, keyCode: 36, modifiers: 0, label: "Return")

    static func singleModifier(_ kind: RecordingShortcutKind) -> RecordingShortcutSetting {
        RecordingShortcutSetting(mode: .custom, kind: kind, keyCode: 0, modifiers: 0, label: ShortcutLabelFormatter.label(for: kind))
    }

    /// Builds a key-combination binding from a key event. Returns nil for keys that cannot be registered.
    static func keyCombination(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> RecordingShortcutSetting? {
        let flags = modifierFlags.intersection([.command, .shift, .option, .control])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        guard keyCode <= 126, let label = ShortcutLabelFormatter.label(keyCode: UInt32(keyCode), modifiers: carbon) else { return nil }
        return RecordingShortcutSetting(mode: .custom, keyCode: UInt32(keyCode), modifiers: carbon, label: label)
    }

    /// The label shown in the overlay and settings, or nil when this binding is inactive.
    func displayLabel(primary: String?) -> String? {
        switch mode {
        case .disabled: return nil
        case .sameAsPrimary: return primary
        case .custom:
            guard !label.isEmpty else { return nil }
            return kind.isSingleModifier ? ShortcutLabelFormatter.label(for: kind) : ShortcutLabelFormatter.label(keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// True when two custom bindings would trigger on the same key.
    func conflicts(with other: RecordingShortcutSetting) -> Bool {
        mode == .custom && other.mode == .custom && kind == other.kind
            && (kind != .keyCombination || (keyCode == other.keyCode && modifiers == other.modifiers))
    }

    /// Validates bindings in the Rust order: cancel, paste, send, copy. Only paste may follow the start shortcut.
    static func validationError(_ bindings: [RecordingShortcutSetting]) -> String? {
        for (index, binding) in bindings.enumerated() {
            if (binding.mode == .sameAsPrimary && index != 1) || binding.keyCode > 126 || binding.modifiers & ~UInt32(6912) != 0
                || binding.label.utf8.count > 64 || (binding.mode == .custom && binding.label.trimmingCharacters(in: .whitespaces).isEmpty)
                || binding.label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return String(localized: "The recording shortcut settings are not valid.", bundle: .module)
            }
            if bindings[..<index].contains(where: { $0.conflicts(with: binding) }) {
                return String(localized: "Use a different shortcut for each recording action.", bundle: .module)
            }
        }
        return nil
    }
}

enum ShortcutLabelFormatter {
    static func label(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard let key = keyLabel(keyCode: UInt16(keyCode)) else { return nil }
        var label = ""
        if modifiers & UInt32(controlKey) != 0 { label += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { label += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { label += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { label += "⌘" }
        return label + key
    }

    static func label(for kind: RecordingShortcutKind) -> String {
        switch kind {
        case .singleControl: "⌃"
        case .singleOption: "⌥"
        case .singleShift: "⇧"
        case .singleCommand: "⌘"
        case .keyCombination: ""
        }
    }

    static func keyLabel(keyCode: UInt16) -> String? { keyLabels[keyCode] }

    private static let keyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc", 64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
        76: "Keypad Enter", 78: "Keypad -", 79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
        84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20",
        91: "Keypad 8", 92: "Keypad 9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑",
    ]
}
