import AppKit
import Carbon.HIToolbox

/// A key combination. Stored in the Tauri app's accelerator format, for example `shift+super+KeyV`,
/// so shortcuts saved by the Tauri app keep working.
public struct Shortcut: Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: NSEvent.ModifierFlags

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
    }

    public static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// Release builds keep the existing ⌘⇧Space. Development builds use ⌃⇧Space so they can run beside the
    /// installed Prism without fighting over its shortcut (⌃⌥Space often switches input sources).
    public static var launcherDefault: Shortcut {
        Bundle.main.bundleIdentifier == AppPaths.releaseBundleIdentifier
            ? Shortcut(keyCode: UInt32(kVK_Space), modifiers: [.command, .shift])
            : Shortcut(keyCode: UInt32(kVK_Space), modifiers: [.control, .shift])
    }

    /// Whether macOS already uses this combination for an enabled system shortcut, such as ⌃Space or ⌃⌥Space
    /// for switching input sources. The system handles those first, so a Prism hotkey would never fire.
    public var isUsedBySystem: Bool {
        guard let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return false }
        let mask: UInt = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
        return hotKeys.values.contains { entry in
            guard let entry = entry as? [String: Any], (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int],
                  parameters.count == 3
            else { return false }
            return UInt32(parameters[1]) == keyCode && UInt(parameters[2]) & mask == modifiers.rawValue & mask
        }
    }

    /// Parses `super+Space`, `shift+super+KeyV`, `alt+Digit1` or `CommandOrControl+Shift+Space`.
    public init?(accelerator: String) {
        var modifiers: NSEvent.ModifierFlags = []
        var keyCode: UInt32?
        for part in accelerator.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part.lowercased() {
            case "super", "cmd", "command", "meta", "commandorcontrol", "cmdorctrl": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "option": modifiers.insert(.option)
            case "control", "ctrl": modifiers.insert(.control)
            default:
                guard keyCode == nil, let code = Self.keyCodes[part] ?? Self.keyCodes[Self.canonicalKey(part)] else { return nil }
                keyCode = code
            }
        }
        guard let keyCode else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// The accelerator string, in the same modifier order the Tauri app writes.
    public var accelerator: String {
        var parts: [String] = []
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.command) { parts.append("super") }
        parts.append(Self.keyNames[keyCode] ?? "Unknown")
        return parts.joined(separator: "+")
    }

    /// Each modifier and the key as separate caps, as the Tauri `kbd` row shows them.
    public var displayKeys: [String] {
        var keys: [String] = []
        if modifiers.contains(.control) { keys.append("⌃") }
        if modifiers.contains(.option) { keys.append("⌥") }
        if modifiers.contains(.shift) { keys.append("⇧") }
        if modifiers.contains(.command) { keys.append("⌘") }
        keys.append(Self.keyDisplayNames[keyCode] ?? Self.keyNames[keyCode].map(Self.shortName) ?? "?")
        return keys
    }

    public var displayName: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + (Self.keyDisplayNames[keyCode] ?? Self.keyNames[keyCode].map(Self.shortName) ?? "?")
    }

    fileprivate var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    private static func canonicalKey(_ key: String) -> String {
        if key.count == 1, let character = key.uppercased().first {
            if character.isLetter { return "Key\(character)" }
            if character.isNumber { return "Digit\(character)" }
        }
        return key
    }

    private static func shortName(_ code: String) -> String {
        if code.hasPrefix("Key") || code.hasPrefix("Digit") { return String(code.drop { $0.isLowercase || $0 == "K" || $0 == "D" }) }
        return code
    }

    /// W3C `KeyboardEvent.code` names, which the Tauri accelerators use.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        let letters: [(String, Int)] = [
            ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E), ("F", kVK_ANSI_F),
            ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L),
            ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O), ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R),
            ("S", kVK_ANSI_S), ("T", kVK_ANSI_T), ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X),
            ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z),
        ]
        for (letter, code) in letters { names[UInt32(code)] = "Key\(letter)" }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in digits.enumerated() { names[UInt32(code)] = "Digit\(digit)" }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { names[UInt32(code)] = "F\(index + 1)" }
        let others: [(String, Int)] = [
            ("Space", kVK_Space), ("Enter", kVK_Return), ("Escape", kVK_Escape), ("Tab", kVK_Tab), ("Backspace", kVK_Delete),
            ("Delete", kVK_ForwardDelete), ("ArrowUp", kVK_UpArrow), ("ArrowDown", kVK_DownArrow), ("ArrowLeft", kVK_LeftArrow),
            ("ArrowRight", kVK_RightArrow), ("Home", kVK_Home), ("End", kVK_End), ("PageUp", kVK_PageUp), ("PageDown", kVK_PageDown),
            ("Minus", kVK_ANSI_Minus), ("Equal", kVK_ANSI_Equal), ("BracketLeft", kVK_ANSI_LeftBracket),
            ("BracketRight", kVK_ANSI_RightBracket), ("Backslash", kVK_ANSI_Backslash), ("Semicolon", kVK_ANSI_Semicolon),
            ("Quote", kVK_ANSI_Quote), ("Comma", kVK_ANSI_Comma), ("Period", kVK_ANSI_Period), ("Slash", kVK_ANSI_Slash),
            ("Backquote", kVK_ANSI_Grave),
        ]
        for (name, code) in others { names[UInt32(code)] = name }
        return names
    }()

    static let keyCodes: [String: UInt32] = Dictionary(uniqueKeysWithValues: keyNames.map { ($1, $0) })

    private static let keyDisplayNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Grave): "`",
    ]
}

public struct HotKeyRegistrationError: Error {
    public let status: OSStatus
}

/// A system-wide shortcut. Carbon's hot key API needs no Accessibility permission, unlike event taps.
/// The registration lasts until this object is released.
@MainActor
public final class GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    nonisolated static let signature = OSType(0x5052_534D) // "PRSM"

    public let shortcut: Shortcut
    private let id: UInt32
    private var reference: EventHotKeyRef?

    public init(shortcut: Shortcut, action: @escaping () -> Void) throws {
        Self.installHandlerIfNeeded()
        self.shortcut = shortcut
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { throw HotKeyRegistrationError(status: status) }
        Self.actions[id] = action
    }

    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Other code in the process may register its own hot keys; leave those to their handlers.
            guard hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // Carbon delivers application events on the main thread.
            return MainActor.assumeIsolated {
                guard let action = GlobalHotKey.actions[id] else { return OSStatus(eventNotHandledErr) }
                action()
                return noErr
            }
        }, 1, &eventType, nil, nil)
    }
}

public enum CommandShortcuts {
    /// Posted after the shell saves `command-shortcuts-v1.json`, so features that read their own entries
    /// (dictation's double-tap keys) pick up changes.
    public static let didChangeNotification = Notification.Name("PrismCommandShortcutsDidChange")
}
