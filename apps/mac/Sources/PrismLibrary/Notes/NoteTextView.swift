import AppKit
import PrismKit
import SwiftUI

/// A borderless Markdown source editor on NSTextView. Headings, list markers, quotes and code are styled in
/// place while the source text stays exactly as typed. Styling waits while an input method is composing.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    /// Changes when another note is opened, so the view replaces its text and moves the caret to the start.
    var documentID: String
    var isEditable: Bool
    var focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        let textView = NoteEditorTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NoteStyle.inset
        textView.insertionPointColor = NSColor(PrismTheme.textSecondary)
        textView.font = NoteStyle.body
        textView.typingAttributes = NoteStyle.bodyAttributes
        textView.setAccessibilityLabel(L10n.tr("Note content"))
        context.coordinator.textView = textView
        context.coordinator.load(text, documentID: documentID)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.isEditable = isEditable
        if coordinator.documentID != documentID || (textView.string != text && !textView.hasMarkedText()) {
            coordinator.load(text, documentID: documentID)
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        weak var textView: NSTextView?
        var documentID = ""
        var focusToken = -1

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func load(_ text: String, documentID: String) {
            guard let textView else { return }
            let isNewDocument = self.documentID != documentID
            self.documentID = documentID
            let selection = textView.selectedRanges
            textView.string = text
            NoteStyle.apply(to: textView)
            if isNewDocument {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.undoManager?.removeAllActions()
                textView.scroll(.zero)
            } else {
                textView.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= (text as NSString).length }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if !textView.hasMarkedText() { NoteStyle.apply(to: textView) }
            parent.text = textView.string
        }
    }
}

/// Escape leaves the notes screen (the palette pops it) instead of opening completions, unless an input
/// method is composing.
final class NoteEditorTextView: NSTextView {
    override func cancelOperation(_ sender: Any?) {
        guard !hasMarkedText() else { return super.cancelOperation(sender) }
        window?.cancelOperation(sender)
    }

    override func complete(_ sender: Any?) {
        guard !hasMarkedText() else { return super.complete(sender) }
        window?.cancelOperation(sender)
    }
}

@MainActor
enum NoteStyle {
    /// `.notes-writing`: 15-point text with a 1.85 line height, inset 16 from the top and about 44 from the sides.
    static let inset = NSSize(width: 39, height: 16)
    static let body = NSFont.systemFont(ofSize: 15)
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 9
        return style
    }()
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor(PrismTheme.text), .paragraphStyle: paragraph]
    }

    /// Restyles the whole document. Notes are at most 128 KB, so this stays fast.
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: NSRange(location: 0, length: text.length))
        var inCode = false
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = text.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                       .foregroundColor: NSColor(PrismTheme.textSecondary)], range: range)
                return
            }
            if inCode {
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: range)
                return
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                let size: CGFloat = [24, 20, 17, 15, 15, 15][hashes - 1]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: hashes <= 2 ? .bold : .semibold), range: range)
                let markerLength = (line as NSString).range(of: String(repeating: "#", count: hashes)).upperBound
                storage.addAttribute(.foregroundColor, value: NSColor(PrismTheme.textMuted),
                                     range: NSRange(location: range.location, length: min(markerLength, range.length)))
            } else if trimmed.hasPrefix(">") {
                storage.addAttribute(.foregroundColor, value: NSColor(PrismTheme.textSecondary), range: range)
            } else if let marker = listMarkerLength(line) {
                storage.addAttribute(.foregroundColor, value: NSColor(PrismTheme.textMuted),
                                     range: NSRange(location: range.location, length: marker))
            }
        }
        storage.endEditing()
        textView.typingAttributes = bodyAttributes
    }

    private static func listMarkerLength(_ line: String) -> Int? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " else { return nil }
        var length = indent.utf16.count + 2
        for task in ["[ ] ", "[x] ", "[X] "] where rest.dropFirst(2).hasPrefix(task) { length += 4 }
        return length
    }
}
