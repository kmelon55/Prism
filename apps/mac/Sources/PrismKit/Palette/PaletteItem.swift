import AppKit
import PrismCore
import SwiftUI

/// One row in the launcher. Providers build items; the palette ranks, groups and presents them.
public struct PaletteItem: Identifiable {
    public var id: String { candidate.id }
    public var candidate: SearchCandidate
    public var icon: PaletteIcon
    /// Short trailing label such as "Application" or "Command".
    public var accessory: String
    /// The first action runs on Return. The rest appear in the ⌘K action panel.
    public var actions: [PaletteAction]
    /// Keeps the row out of the root list until the user types, for large command families such as window
    /// layouts. Providers still return it for the empty query so hotkeys and the Shortcuts settings find it.
    public var hiddenWhenQueryIsEmpty: Bool
    /// Puts the row above everything else, favorites included, while the query is empty. For rare, timely rows
    /// such as a ready update.
    public var leadsEmptyQuery: Bool

    public init(
        candidate: SearchCandidate, icon: PaletteIcon, accessory: String = "", actions: [PaletteAction],
        hiddenWhenQueryIsEmpty: Bool = false, leadsEmptyQuery: Bool = false
    ) {
        self.candidate = candidate
        self.icon = icon
        self.accessory = accessory
        self.actions = actions
        self.hiddenWhenQueryIsEmpty = hiddenWhenQueryIsEmpty
        self.leadsEmptyQuery = leadsEmptyQuery
    }

    public var title: String { candidate.title }
    public var subtitle: String { candidate.subtitle }
    public var section: String { candidate.section }
}

public enum PaletteIcon {
    case symbol(String, tint: Color? = nil)
    /// Finder icon for any file, folder or application bundle path. Cached and loaded lazily.
    case file(path: String)
    case image(NSImage)
    /// Emoji or a short glyph drawn as text.
    case text(String)
    case none
}

public struct PaletteAction: Identifiable {
    public let id: String
    public var title: String
    public var systemImage: String?
    /// Runs while the item is selected, without opening the action panel. Return always runs the first action.
    public var shortcut: KeyboardShortcut?
    public var isDestructive: Bool
    public var run: @MainActor () async -> PaletteActionOutcome

    public init(
        id: String, title: String, systemImage: String? = nil, shortcut: KeyboardShortcut? = nil,
        isDestructive: Bool = false, run: @escaping @MainActor () async -> PaletteActionOutcome
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.run = run
    }
}

public enum PaletteActionOutcome {
    /// Hide the palette, for example after launching an app or pasting.
    case dismiss
    /// Keep the palette and its query, for example after copying.
    case keepOpen
    /// Show a full-palette screen on top of the root search. Escape returns.
    case push(PaletteScreen)
    /// Keep the palette open and show a short confirmation such as "Copied".
    case notify(String)
    /// Keep the palette open and ask every provider again for the current query, for example to retry a
    /// failed answer.
    case refresh
}

/// A feature-owned view that replaces the root results, such as clipboard history or the emoji picker.
/// The screen owns its own search field and keyboard handling. The palette handles Escape.
public struct PaletteScreen: Identifiable {
    public let id: String
    public var title: String
    /// Grows the palette into the larger workspace (1080×760, as in the Tauri app) while this screen is on top.
    /// The palette shrinks back when the screen is popped.
    public var expanded: Bool
    public var content: @MainActor () -> AnyView

    public init<Content: View>(id: String, title: String, expanded: Bool = false, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = title
        self.expanded = expanded
        self.content = { AnyView(content()) }
    }
}
