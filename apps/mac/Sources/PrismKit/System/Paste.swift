import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum Permissions {
    /// Accessibility is needed to paste into other apps, manage windows and expand snippets.
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @MainActor
    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

@MainActor
public enum PasteService {
    public enum PasteError: Error {
        case accessibilityNotTrusted
    }

    public static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    public static func copy(_ items: [any NSPasteboardWriting]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    /// Puts `string` on the clipboard and pastes it into `target`. The palette must already be hidden.
    /// Without Accessibility permission the text stays on the clipboard and this throws.
    public static func paste(_ string: String, into target: NSRunningApplication?) async throws {
        copy(string)
        try await pasteClipboard(into: target)
    }

    /// Sends ⌘V to `target` (or the frontmost app) for whatever is already on the clipboard.
    public static func pasteClipboard(into target: NSRunningApplication?) async throws {
        guard Permissions.isAccessibilityTrusted else { throw PasteError.accessibilityNotTrusted }
        if let target, !target.isActive {
            target.activate()
            // Give the target a moment to become key before the keystroke arrives.
            try? await Task.sleep(for: .milliseconds(80))
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
