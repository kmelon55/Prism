import AppKit
import Testing
@testable import PrismKit

@MainActor
struct PointerSelectionTests {
    @Test func tracksMovementWithoutStealingClicksOrSelectingOnEntry() throws {
        let view = PointerSelectionView {}
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        let area = try #require(view.trackingAreas.first)
        #expect(area.options.contains(.mouseMoved))
        #expect(area.options.contains(.inVisibleRect))
        #expect(area.options.contains(.activeInKeyWindow))
        #expect(!area.options.contains(.mouseEnteredAndExited))
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func selectsOnMovementWithinTheSameRowButNotStationaryEvents() throws {
        var selections = 0
        let view = PointerSelectionView { selections += 1 }
        let raw = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: CGPoint(x: 20, y: 20), mouseButton: .left))
        view.mouseMoved(with: try #require(NSEvent(cgEvent: raw)))
        #expect(selections == 0)
        raw.setIntegerValueField(.mouseEventDeltaX, value: 1)
        let movement = try #require(NSEvent(cgEvent: raw))
        view.mouseMoved(with: movement)
        view.mouseMoved(with: movement)
        #expect(selections == 2)
        // SwiftUI updates callbacks as rows are reused after a search.
        view.action = { selections += 10 }
        view.mouseMoved(with: movement)
        #expect(selections == 12)
    }
}
