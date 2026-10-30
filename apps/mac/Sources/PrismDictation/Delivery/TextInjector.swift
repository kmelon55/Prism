// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit
import ApplicationServices
import OSLog

/// The app and focused element captured when a recording starts.
struct TextInsertionTarget {
    let processIdentifier: pid_t
    let focusedElement: AXUIElement?
    let application: NSRunningApplication
}

/// What the focused text value should look like after a paste, to tell a confirmed insertion apart.
struct TextInsertionExpectation {
    let original: String
    let expected: String

    init?(value: String, range: CFRange, text: String) {
        let original = value as NSString
        guard range.location >= 0, range.length >= 0, range.location <= original.length,
              range.length <= original.length - range.location else { return nil }
        self.original = value
        expected = original.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }

    /// An unchanged AX value is not evidence that the app accepted an insertion.
    func confirms(_ value: String?) -> Bool {
        expected != original && value == expected
    }
}

enum TextDeliveryResult: Equatable, Sendable {
    case inserted, pasted, pasteSent, copied, permissionRequired, copyFailed, unverified, sendFailed

    var enteredInTargetApp: Bool { self == .inserted || self == .pasted }

    var fallbackMessage: String {
        switch self {
        case .copyFailed: String(localized: "Could not copy the text. Copy the last result again in settings.", bundle: .module)
        case .permissionRequired: String(localized: "Accessibility permission is off, so the text was copied", bundle: .module)
        case .unverified: String(localized: "Could not confirm insertion. The text is on the clipboard.", bundle: .module)
        case .sendFailed: String(localized: "Could not send automatically. The text is on the clipboard.", bundle: .module)
        default: String(localized: "No insertion point was found, so the text was copied", bundle: .module)
        }
    }
}

/// Puts dictated text on the clipboard and pastes it into the app that was focused when recording started.
/// It never writes AX values; AX is used only to observe whether a paste landed.
@MainActor
enum TextInjector {
    private static let logger = Logger(subsystem: "dev.prism.desktop.dictation", category: "text-delivery")
    /// nspasteboard.org marker that clipboard managers, including Prism's history, skip.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    struct Environment {
        var running: @MainActor (NSRunningApplication) -> Bool = { !$0.isTerminated }
        var permission: @MainActor () -> Bool = { AXIsProcessTrusted() }
        var frontmostPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var activate: @MainActor (NSRunningApplication) -> Void = { $0.activate() }
        var focused: @MainActor (pid_t) -> AXUIElement? = { TextInjector.focusedElement(for: $0) }
        var paste: @MainActor (pid_t) -> Bool = { TextInjector.postKey(9, command: true, to: $0) }
        var enter: @MainActor (pid_t) -> Bool = { TextInjector.postKey(36, command: false, to: $0) }
        var revision: @MainActor () -> Int = { NSPasteboard.general.changeCount }
        var application: @MainActor (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    }

    @discardableResult
    static func copy(_ text: String, saveToHistory: Bool = true) -> Bool {
        copy(text, to: .general, saveToHistory: saveToHistory)
    }

    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard, saveToHistory: Bool = true) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        // Attach the exclusion before publishing so the history monitor cannot race it.
        if !saveToHistory {
            guard item.setString("", forType: transientType) else { return false }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) && pasteboard.string(forType: .string) == text
    }

    /// The frontmost app is the target unless it is Prism itself; then `fallbackPID` decides
    /// (Prism's own PID for in-app dictation, the remembered app for a launcher command, 0 for none).
    static func captureTarget(fallbackPID: pid_t = 0, environment: Environment = Environment()) -> TextInsertionTarget? {
        guard let frontmostPID = environment.frontmostPID() else {
            logger.error("Capture failed: no frontmost application")
            return nil
        }
        let pid = frontmostPID == ProcessInfo.processInfo.processIdentifier ? fallbackPID : frontmostPID
        guard pid > 0 else {
            logger.error("Capture failed: no input target")
            return nil
        }
        guard let application = environment.application(pid), environment.running(application) else { return nil }
        let trusted = environment.permission()
        let element = trusted ? environment.focused(pid) : nil
        logger.notice("Captured target pid=\(pid, privacy: .public), trusted=\(trusted, privacy: .public), element=\(element != nil, privacy: .public)")
        return TextInsertionTarget(processIdentifier: pid, focusedElement: element, application: application)
    }

    static func deliver(_ text: String, paste: Bool, pressEnterAfterPaste: Bool, target: TextInsertionTarget?,
                        copyText: @MainActor (String) -> Bool = { TextInjector.copy($0) },
                        environment: Environment = Environment()) async -> TextDeliveryResult {
        guard !Task.isCancelled else { return .copied }
        // Keep every result on the clipboard first. An app can receive Command-V without accepting the text.
        guard copyText(text) else { return .copyFailed }
        guard paste else {
            logger.notice("Delivery copied: auto-paste disabled")
            return .copied
        }
        guard environment.permission() else {
            logger.error("Delivery copied: accessibility permission unavailable")
            return .permissionRequired
        }
        guard let target, environment.running(target.application) else {
            logger.error("Delivery copied: recording target missing")
            return .copied
        }
        let targetWasFrontmost = environment.frontmostPID() == target.processIdentifier
        if !targetWasFrontmost { environment.activate(target.application) }

        // Browsers and Electron apps can restore AX focus late after activation. Command-V goes to the
        // saved target even when it exposes no AX text element.
        for delay in targetWasFrontmost ? [20] : [80, 120, 200] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return .copied }
            guard environment.frontmostPID() == target.processIdentifier else {
                environment.activate(target.application)
                continue
            }
            let element = environment.focused(target.processIdentifier)
            guard copyText(text) else { return .copyFailed }
            // Terminals expose hidden text areas whose values do not track pasted input.
            let expectation = target.application.bundleIdentifier == "com.stablyai.orca" ? nil : element.flatMap { insertionExpectation(text, in: $0) }
            let revision = environment.revision()
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return .copied }
            guard environment.revision() == revision, environment.frontmostPID() == target.processIdentifier,
                  environment.paste(target.processIdentifier) else {
                logger.error("Delivery copied: could not create paste events")
                return copyText(text) ? .copied : .copyFailed
            }
            logger.notice("Delivery sent Command-V to pid=\(target.processIdentifier, privacy: .public)")
            var confirmed = false
            if let expectation, let element {
                for delay in [50, 100, 150, 250, 350] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled else { return .copied }
                    if expectation.confirms(attribute(kAXValueAttribute, from: element) as? String) {
                        confirmed = true
                        break
                    }
                }
            }
            return await finishDelivery(pasteResult(observable: expectation != nil, confirmed: confirmed), pressEnter: pressEnterAfterPaste,
                                        processIdentifier: target.processIdentifier, environment: environment)
        }
        logger.error("Delivery copied: target application did not become frontmost")
        return copyText(text) ? .copied : .copyFailed
    }

    static func pasteResult(observable: Bool, confirmed: Bool) -> TextDeliveryResult {
        confirmed ? .pasted : (observable ? .unverified : .pasteSent)
    }

    private static func finishDelivery(_ result: TextDeliveryResult, pressEnter: Bool, processIdentifier: pid_t,
                                       environment: Environment) async -> TextDeliveryResult {
        guard pressEnter, result.enteredInTargetApp || result == .pasteSent else { return result }
        // Give the paste a moment to land before sending Enter.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return result }
        guard environment.frontmostPID() == processIdentifier, environment.enter(processIdentifier) else {
            logger.error("Delivery could not create Enter events")
            return .sendFailed
        }
        return result
    }

    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        // Electron/WebView apps can expose the real editor in a renderer process. When the target is frontmost,
        // prefer the system-wide keyboard focus even if its PID differs.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
            let systemWide = AXUIElementCreateSystemWide()
            if let element = elementAttribute(kAXFocusedUIElementAttribute, from: systemWide),
               processIdentifier == ProcessInfo.processInfo.processIdentifier || !belongs(element, to: ProcessInfo.processInfo.processIdentifier) {
                return element
            }
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        if let element = elementAttribute(kAXFocusedUIElementAttribute, from: application), belongs(element, to: processIdentifier) {
            return element
        }
        return nil
    }

    private static func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, from: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func belongs(_ element: AXUIElement, to processIdentifier: pid_t) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == processIdentifier
    }

    private static func insertionExpectation(_ text: String, in element: AXUIElement) -> TextInsertionExpectation? {
        guard let value = attribute(kAXValueAttribute, from: element) as? String,
              let reference = attribute(kAXSelectedTextRangeAttribute, from: element),
              CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(reference, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return TextInsertionExpectation(value: value, range: range, text: text)
    }

    private static func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func postKey(_ keyCode: CGKeyCode, command: Bool, to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        if command {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }
}
