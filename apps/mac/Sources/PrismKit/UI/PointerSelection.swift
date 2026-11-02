import AppKit
import SwiftUI

public extension View {
    /// Select only on actual movement, never when a row appears beneath a stationary pointer.
    func prismOnPointerMove(perform action: @escaping () -> Void) -> some View {
        background(PointerSelectionRegion(action: action))
    }
}

private struct PointerSelectionRegion: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> PointerSelectionView {
        PointerSelectionView(action: action)
    }

    func updateNSView(_ view: PointerSelectionView, context: Context) {
        view.action = action
    }
}

final class PointerSelectionView: NSView {
    var action: () -> Void
    private var movementArea: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Tracking must not intercept clicks, scrolling, or the search field's focus.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let movementArea { removeTrackingArea(movementArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        movementArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard event.deltaX != 0 || event.deltaY != 0 else { return }
        action()
    }
}
