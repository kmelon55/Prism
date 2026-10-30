import AppKit
import PrismKit
import SwiftUI

/// Editing commands a screen's search field forwards instead of handling as text.
enum SearchFieldCommand: Equatable {
    case up, down, left, right, pageUp, pageDown, submit, commandSubmit, tab, backTab, cancel
}

/// The palette-style search field for feature screens. It keeps focus while arrows, Return and Tab drive the
/// screen, and never forwards a key while an input method is composing (Korean IME): those keys belong to the
/// composition until it is committed.
struct ScreenSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// 14 points in the screen headers, as in the Tauri screens.
    var fontSize: CGFloat = 14
    /// Returns true when the screen handled the command. Unhandled Escape goes to the palette.
    var onCommand: (SearchFieldCommand) -> Bool

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(PrismTheme.text)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.onCommandReturn = { [coordinator = context.coordinator] in coordinator.parent.onCommand(.commandSubmit) }
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: NSColor(PrismTheme.textMuted), .font: NSFont.systemFont(ofSize: fontSize),
            ])
        }
        // Never overwrite the field while it holds uncommitted IME text.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScreenSearchField

        init(parent: ScreenSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            let command: SearchFieldCommand? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.moveLeft(_:)): .left
            case #selector(NSResponder.moveRight(_:)): .right
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): .pageUp
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): .pageDown
            case #selector(NSResponder.insertNewline(_:)): .submit
            case #selector(NSResponder.insertTab(_:)): .tab
            case #selector(NSResponder.insertBacktab(_:)): .backTab
            case #selector(NSResponder.cancelOperation(_:)): .cancel
            default: nil
            }
            guard let command else { return false }
            if parent.onCommand(command) { return true }
            if command == .cancel {
                textView.window?.cancelOperation(nil)
                return true
            }
            return command == .submit || command == .tab || command == .backTab
        }
    }
}

final class FocusingTextField: NSTextField {
    var onCommandReturn: (() -> Bool)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.currentEditor() == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText(),
           modifiers == .command, event.keyCode == 36 || event.keyCode == 76,
           onCommandReturn?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
