import Carbon.HIToolbox
import Foundation

/// Display names for key codes, with letters and symbols read from the current Latin keyboard layout.
enum KeyNames {
    static func caps(for combo: KeyCombo) -> [String] {
        var caps: [String] = []
        if combo.modifiers.contains(.control) { caps.append("⌃") }
        if combo.modifiers.contains(.option) { caps.append("⌥") }
        if combo.modifiers.contains(.shift) { caps.append("⇧") }
        if combo.modifiers.contains(.command) { caps.append("⌘") }
        caps.append(name(for: combo.keyCode))
        return caps
    }

    static func name(for keyCode: UInt16) -> String {
        if let name = special[Int(keyCode)] { return name }
        return layoutCharacter(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    private static let special: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "Help",
            // Caps Lock reaches the tap as F18 while a Caps Lock rule is on.
            kVK_F18: "Caps Lock",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                            kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() where names[code] == nil { names[code] = "F\(index + 1)" }
        return names
    }()

    private static func layoutCharacter(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }
}
