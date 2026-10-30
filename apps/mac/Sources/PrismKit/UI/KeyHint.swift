import SwiftUI

/// A label with its keyboard shortcut, as shown in the palette footer.
public struct KeyHint: View {
    let label: Text
    let keys: String

    public init(_ label: Text, keys: String) {
        self.label = label
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 6) {
            label.font(.system(size: 11, weight: .semibold)).foregroundStyle(PrismTheme.textMuted)
            KeyCap(keys)
        }
    }
}

public struct KeyCap: View {
    let keys: String

    public init(_ keys: String) {
        self.keys = keys
    }

    /// Matches the Tauri `kbd`: a faint bordered cap with small semibold text.
    public var body: some View {
        Text(verbatim: keys)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(PrismTheme.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(PrismTheme.keyCap))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }
}

public extension KeyboardShortcut {
    /// "⌘⇧C" style text for footers and action panels.
    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.displayText
    }
}

public extension KeyEquivalent {
    var displayText: String {
        switch self {
        case .return: "↵"
        case .delete: "⌫"
        case .deleteForward: "⌦"
        case .escape: "⎋"
        case .tab: "⇥"
        case .space: "Space"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        default: String(character).uppercased()
        }
    }
}
