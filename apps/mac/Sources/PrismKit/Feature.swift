import AppKit
import SwiftUI

/// Services the app shell offers to features.
@MainActor
public protocol PrismContext: AnyObject, Sendable {
    var paths: AppPaths { get }
    /// The app that was frontmost before the palette opened. Paste targets this app.
    var previousApplication: NSRunningApplication? { get }
    /// Whether the palette is on screen, so a command can tell a palette launch from a hotkey launch.
    var isPaletteVisible: Bool { get }
    /// The palette's screen frame while it is visible, so a window opened from it can grow out of it.
    var paletteFrame: NSRect? { get }
    func showPalette()
    func hidePalette()
    /// Pushes a screen onto the visible palette, or opens the palette on it (for example from a global hotkey).
    func showPalette(screen: PaletteScreen)
    /// Asks one provider again for the current query when its rows change on their own, such as a running
    /// script's status. Other providers keep their rows.
    func reloadResults(providerID: String)
    /// Hides the palette for a moment without resetting it, for example while the user selects a screen region,
    /// and brings it back as it was.
    func suspendPalette()
    func resumePalette()
    /// Returns from the top palette screen to the one below, keeping the root query. Same as Escape.
    func popScreen()
    func openSettings(paneID: String?)
    /// A short floating confirmation such as "Copied to Clipboard".
    func showHUD(_ message: String)
}

/// Everything one feature adds to the app. Built once at launch.
public struct FeatureContribution {
    public var providers: [any PaletteProvider]
    public var settingsPanes: [SettingsPane]
    /// Starts background work such as clipboard monitoring. Called once after every feature is built.
    public var start: @MainActor () -> Void

    public init(providers: [any PaletteProvider] = [], settingsPanes: [SettingsPane] = [], start: @escaping @MainActor () -> Void = {}) {
        self.providers = providers
        self.settingsPanes = settingsPanes
        self.start = start
    }
}

/// One entry in the Settings sidebar.
public struct SettingsPane: Identifiable {
    /// The sidebar sections of the Tauri settings window.
    public enum Group: Int, CaseIterable, Sendable {
        case preferences, tools, privacy
    }

    public let id: String
    public var title: String
    public var systemImage: String
    public var group: Group
    /// Position within the group. Lower comes first.
    public var order: Int
    /// Extra words the settings search matches, such as the labels of the pane's rows.
    public var keywords: [String]
    /// The pane draws its own `PrismSettingsPage`; the window only supplies the glass and the sidebar.
    public var content: @MainActor () -> AnyView

    public init<Content: View>(id: String, title: String, systemImage: String, group: Group = .preferences, order: Int,
                               keywords: [String] = [], @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.group = group
        self.order = order
        self.keywords = keywords
        self.content = { AnyView(content()) }
    }
}

public extension PrismContext {
    /// Default for test doubles. The app shell implements the real behavior.
    func popScreen() {}
    func suspendPalette() {}
    func resumePalette() {}
    func reloadResults(providerID: String) {}
    var isPaletteVisible: Bool { false }
    var paletteFrame: NSRect? { nil }
}
