import AppKit
import PrismKit
import SwiftUI

/// The chat composer: Return sends, Shift/Option-Return inserts a newline, and nothing acts on Return or Escape while
/// an input method is composing (Korean, Japanese, Chinese). Two lines tall at rest (14 pt on a 1.5 line height,
/// as the Tauri textarea), growing with its text up to 180 points.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var isEnabled: Bool
    var focusToken: Int
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onPasteImage: (Data) -> Void

    static let minHeight: CGFloat = 46
    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 21
    static let maxHeight: CGFloat = 180

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: Self.fontSize)
        textView.textColor = ComposerNSTextView.textColor
        textView.insertionPointColor = ComposerNSTextView.textColor
        textView.defaultParagraphStyle = ComposerNSTextView.paragraph
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: Self.fontSize), .foregroundColor: ComposerNSTextView.textColor,
                                     .paragraphStyle: ComposerNSTextView.paragraph]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(L("AI message"))
        scroll.documentView = textView
        textView.string = text
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.updateHeight()
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.placeholder = placeholder
        textView.needsDisplay = true
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                if isEnabled, let window = textView.window { window.makeFirstResponder(textView) }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var focusToken = -1

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Keep composing text local until the input method commits it.
            if !textView.hasMarkedText(), parent.text != textView.string { parent.text = textView.string }
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(max(ceil(used), ComposerTextView.minHeight), ComposerTextView.maxHeight)
            if abs(parent.height - height) > 0.5 { parent.height = height }
        }

        func submit() { if parent.isEnabled { parent.onSubmit() } }
        func escape() { parent.onEscape() }
        func pasteImage(_ data: Data) { parent.onPasteImage(data) }
        var isEnabled: Bool { parent.isEnabled }
    }
}

final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    var placeholder = ""

    /// `--text` and `--text-muted`, resolved per appearance.
    static let textColor = NSColor(name: nil) { PrismTheme.isDark($0) ? NSColor(white: 0xF3 / 255.0, alpha: 1) : NSColor(white: 0x24 / 255.0, alpha: 1) }
    static let placeholderColor = NSColor(name: nil) { PrismTheme.isDark($0) ? NSColor(white: 0x99 / 255.0, alpha: 1) : NSColor(white: 0x73 / 255.0, alpha: 1) }
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = ComposerTextView.lineHeight
        style.maximumLineHeight = ComposerTextView.lineHeight
        return style
    }()

    override func keyDown(with event: NSEvent) {
        // While an input method has marked text, Return and Escape belong to it.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if modifiers.isEmpty {
                if !event.isARepeat { coordinator?.submit() }
                return
            }
            if modifiers == .shift || modifiers == .option {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
        case 53: // Escape
            coordinator?.escape()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            coordinator?.pasteImage(data)
            return
        }
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: ComposerTextView.fontSize),
                                                         .foregroundColor: Self.placeholderColor, .paragraphStyle: Self.paragraph]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(in: NSRect(origin: origin, size: NSSize(width: bounds.width - origin.x, height: ComposerTextView.lineHeight + 4)),
                                       withAttributes: attributes)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}
