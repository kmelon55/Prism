import AppKit
import QuartzCore
import SwiftUI

/// One native highlight and tracking area for the whole list. Pointer feedback is painted in the
/// same event that changes selection, without waiting for SwiftUI preferences to make another pass.
public struct ListSelectionSurface: NSViewRepresentable {
    public var rows: [String: CGRect]
    public var selectedID: String?
    public var enabled: Bool
    public var onSelect: (String) -> Void

    public init(rows: [String: CGRect], selectedID: String?, enabled: Bool = true, onSelect: @escaping (String) -> Void) {
        self.rows = rows; self.selectedID = selectedID; self.enabled = enabled; self.onSelect = onSelect
    }

    public func makeNSView(context: Context) -> ListSelectionView { ListSelectionView() }
    public func updateNSView(_ view: ListSelectionView, context: Context) {
        view.rows = rows
        view.enabled = enabled
        view.onSelect = onSelect
        view.select(selectedID)
    }
}

public final class ListSelectionView: NSView {
    public override var isFlipped: Bool { true }
    var rows: [String: CGRect] = [:]
    var enabled = true
    var onSelect: (String) -> Void = { _ in }
    private(set) var selectedID: String?
    private let highlight = CAGradientLayer()
    private var movementArea: NSTrackingArea?
    var highlightFrame: CGRect { highlight.frame }
    var highlightAnimationKeys: [String] { highlight.animationKeys() ?? [] }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        highlight.cornerRadius = 7
        highlight.cornerCurve = .continuous
        highlight.startPoint = CGPoint(x: 0.5, y: 0)
        highlight.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(highlight)
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }

    private func updateColors() {
        let dark = PrismTheme.isDark(effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.colors = [NSColor(white: dark ? 1 : 0, alpha: CGFloat(dark ? 0x17 : 0x09) / 255).cgColor,
                            NSColor(white: dark ? 1 : 0, alpha: CGFloat(dark ? 0x0D : 0x06) / 255).cgColor]
        CATransaction.commit()
    }

    func select(_ id: String?) {
        selectedID = id
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.isHidden = id.flatMap { rows[$0] } == nil
        if let id, let rect = rows[id] { highlight.frame = rect }
        CATransaction.commit()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let movementArea { removeTrackingArea(movementArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        movementArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        guard event.deltaX != 0 || event.deltaY != 0 else { return }
        selectFromPointer(at: convert(event.locationInWindow, from: nil))
    }

    func selectFromPointer(at point: CGPoint) {
        guard enabled, let id = rows.first(where: { $0.value.contains(point) })?.key, id != selectedID else { return }
        select(id)
        onSelect(id)
    }
}
