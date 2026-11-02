import AppKit
import Testing
@testable import PrismKit

@MainActor
struct ListSelectionTests {
    @Test func rapidMovementPaintsImmediatelyAndOnlyPublishesRowChanges() {
        let view = ListSelectionView()
        view.rows = ["first": CGRect(x: 0, y: 0, width: 300, height: 38),
                     "second": CGRect(x: 0, y: 56, width: 300, height: 38)]
        var changes: [String] = []
        view.onSelect = { id in
            #expect(view.highlightFrame == view.rows[id])
            #expect(view.highlightAnimationKeys.isEmpty)
            changes.append(id)
        }
        view.select("first")
        for _ in 0..<100 {
            view.selectFromPointer(at: CGPoint(x: 30, y: 70))
            view.selectFromPointer(at: CGPoint(x: 100, y: 70))
            view.selectFromPointer(at: CGPoint(x: 30, y: 20))
        }
        #expect(changes.count == 200)
        #expect(view.selectedID == "first")
        view.selectFromPointer(at: CGPoint(x: 30, y: 45)) // Section heading.
        #expect(changes.count == 200)
        view.enabled = false
        view.selectFromPointer(at: CGPoint(x: 30, y: 70))
        #expect(view.selectedID == "first")
        view.select("second") // Keyboard selection uses the same single layer.
        #expect(view.highlightFrame == view.rows["second"])
        #expect(view.hitTest(.zero) == nil)
    }
}
