import AppKit
import SwiftUI

public extension NSApplication {
    /// Brings Prism forward for a window the user just asked for (Settings, AI Chat, an editor).
    ///
    /// The palette never activates Prism, so another app stays active while it is open. The cooperative
    /// `activate()` of macOS 14 is ignored in that state, and the window would open behind the active app and
    /// spend clicks on activation. The forced form is deprecated but still honored.
    func bringForward() {
        activate(ignoringOtherApps: true)
    }
}

/// A hosting view whose controls take the first click even while Prism is not the active app, which is always the
/// case for the non-activating palette.
public final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
