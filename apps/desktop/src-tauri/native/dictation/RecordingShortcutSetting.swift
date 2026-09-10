// Reused from Whisp AppSettings.swift. MIT; see LICENSE-Whisp.
import Carbon.HIToolbox
import Foundation
enum RecordingShortcutMode: String, CaseIterable, Identifiable, Codable {
    case sameAsPrimary
    case custom
    case disabled

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .sameAsPrimary: return language.text("녹음 시작과 동일", "Same as start shortcut")
        case .custom: return language.text("사용자 지정", "Custom")
        case .disabled: return language.text("지정 안 함", "None")
        }
    }
}

enum RecordingShortcutAction: CaseIterable, Identifiable {
    case cancel
    case paste
    case pasteAndEnter

    var id: Self { self }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .cancel: return language.text("취소", "Cancel")
        case .paste: return language.text("붙여넣기", "Paste")
        case .pasteAndEnter: return language.text("붙여넣고 Enter", "Paste & Enter")
        }
    }

    func subtitle(_ language: AppLanguage) -> String {
        switch self {
        case .cancel:
            return language.text("API 요청 없이 녹음을 버립니다.", "Discard the recording without an API request.")
        case .paste:
            return language.text("전사한 문장을 현재 앱에 붙여넣습니다.", "Paste the transcript into the current app.")
        case .pasteAndEnter:
            return language.text("붙여넣은 뒤 Enter까지 누릅니다.", "Paste the transcript, then press Enter.")
        }
    }
}

enum RecordingShortcutKind: String, Codable, Hashable {
    case keyCombination
    case singleControl
    case singleOption
    case singleShift
    case singleCommand

    var isSingleModifier: Bool { self != .keyCombination }
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
        case .singleControl: return "⌃"
        case .singleOption: return "⌥"
        case .singleShift: return "⇧"
        case .singleCommand: return "⌘"
        case .keyCombination: return ""
        }
    }

    static func keyLabel(keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 53: return "Esc"
        case 64: return "F17"
        case 65: return "Keypad ."
        case 67: return "Keypad *"
        case 69: return "Keypad +"
        case 71: return "Clear"
        case 75: return "Keypad /"
        case 76: return "Keypad Enter"
        case 78: return "Keypad -"
        case 79: return "F18"
        case 80: return "F19"
        case 81: return "Keypad ="
        case 82: return "Keypad 0"
        case 83: return "Keypad 1"
        case 84: return "Keypad 2"
        case 85: return "Keypad 3"
        case 86: return "Keypad 4"
        case 87: return "Keypad 5"
        case 88: return "Keypad 6"
        case 89: return "Keypad 7"
        case 90: return "F20"
        case 91: return "Keypad 8"
        case 92: return "Keypad 9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Forward Delete"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}

struct RecordingShortcutSetting: Codable, Equatable {
    var mode: RecordingShortcutMode
    var kind: RecordingShortcutKind
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    init(
        mode: RecordingShortcutMode,
        kind: RecordingShortcutKind = .keyCombination,
        keyCode: UInt32,
        modifiers: UInt32,
        label: String
    ) {
        self.mode = mode
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case kind
        case keyCode
        case modifiers
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(RecordingShortcutMode.self, forKey: .mode)
        kind = try container.decodeIfPresent(RecordingShortcutKind.self, forKey: .kind)
            ?? .keyCombination
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        label = try container.decode(String.self, forKey: .label)
    }

    static let cancelDefault = RecordingShortcutSetting(
        mode: .custom,
        keyCode: 53,
        modifiers: 0,
        label: "Esc"
    )
    static let pasteDefault = RecordingShortcutSetting(
        mode: .sameAsPrimary,
        keyCode: 0,
        modifiers: 0,
        label: ""
    )
    static let pasteAndEnterDefault = RecordingShortcutSetting(
        mode: .custom,
        keyCode: 36,
        modifiers: 0,
        label: "Return"
    )
}
