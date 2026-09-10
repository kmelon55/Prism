// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import AppKit
import ApplicationServices
import OSLog

struct TextInsertionTarget {
    let processIdentifier: pid_t
    let focusedElement: AXUIElement?
    let application: NSRunningApplication
}

enum TextDeliveryResult: Equatable {
    case inserted
    case pasted
    case copied
    case permissionRequired
    case copyFailed

    var enteredInTargetApp: Bool {
        self == .inserted || self == .pasted
    }

    func fallbackMessage(_ language: AppLanguage) -> String {
        switch self {
        case .copyFailed:
            return language.text("클립보드에 복사하지 못했어요. 설정에서 마지막 결과를 다시 복사하세요.", "Could not copy the text. Copy the last result again in settings.")
        case .permissionRequired:
            return language.text(
                "손쉬운 사용 권한이 꺼져 있어 클립보드에 복사했어요",
                "Accessibility permission is off, so the text was copied"
            )
        default:
            return language.text(
                "입력 위치를 찾지 못해 클립보드에 복사했어요",
                "No insertion point was found, so the text was copied"
            )
        }
    }
}

@MainActor
enum TextInjector {
    private static let logger = Logger(
        subsystem: "dev.prism.desktop.dictation",
        category: "text-delivery"
    )

    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) else { return false }
        pasteboard.clearContents()
        // Respect Prism's transient clipboard filter; do not persist dictated text in history.
        return pasteboard.writeObjects([item])
    }

    static func captureTarget(fallbackPID: pid_t = 0) -> TextInsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            logger.error("Capture failed: no frontmost application")
            return nil
        }
        let pid = application.processIdentifier == ProcessInfo.processInfo.processIdentifier ? fallbackPID : application.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            logger.error("Capture failed: Prism is frontmost")
            return nil
        }

        guard let targetApplication = NSRunningApplication(processIdentifier: pid), !targetApplication.isTerminated else { return nil }
        let element = hasAccessibilityPermission ? focusedElement(for: pid) : nil
        logger.notice(
            "Captured target pid=\(pid, privacy: .public), trusted=\(hasAccessibilityPermission, privacy: .public), element=\(element != nil, privacy: .public)"
        )

        return TextInsertionTarget(
            processIdentifier: pid,
            focusedElement: element,
            application: targetApplication
        )
    }

    static func deliver(
        _ text: String,
        paste: Bool,
        pressEnterAfterPaste: Bool,
        target: TextInsertionTarget?
    ) async -> TextDeliveryResult {
        guard !Task.isCancelled else { return .copied }
        guard paste else {
            logger.notice("Delivery copied: auto-paste disabled")
            return copy(text) ? .copied : .copyFailed
        }

        guard hasAccessibilityPermission else {
            logger.error("Delivery copied: accessibility permission unavailable")
            return copy(text) ? .permissionRequired : .copyFailed
        }

        guard let target, !target.application.isTerminated else {
            logger.error("Delivery copied: recording target missing")
            return copy(text) ? .copied : .copyFailed
        }

        // Orca's terminal exposes a hidden textarea through AX. Setting its value
        // reports success but does not emit terminal input; use its paste handler.
        let usePasteShortcut = target.application.bundleIdentifier == "com.stablyai.orca"
        // 녹음 시작 때 저장한 요소와 현재 앱이 보고하는 포커스 요소를 모두 확인합니다.
        if !usePasteShortcut, let element = target.focusedElement, insertDirectly(text, into: element) {
            logger.notice("Delivery inserted into captured AX element")
            return await finishDelivery(
                .inserted,
                pressEnter: pressEnterAfterPaste,
                processIdentifier: target.processIdentifier
            )
        }
        if !usePasteShortcut, let element = focusedElement(for: target.processIdentifier),
           insertDirectly(text, into: element) {
            logger.notice("Delivery inserted into current AX element")
            return await finishDelivery(
                .inserted,
                pressEnter: pressEnterAfterPaste,
                processIdentifier: target.processIdentifier
            )
        }

        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            logger.error("Delivery copied: target pid=\(target.processIdentifier, privacy: .public) is not running")
            return copy(text) ? .copied : .copyFailed
        }

        let targetWasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == target.processIdentifier
        if !targetWasFrontmost {
            application.activate()
        }

        // 브라우저와 Electron 앱은 활성화 직후 AX 포커스를 늦게 복원할 수 있습니다.
        // AX 삽입이 지원되지 않아도 저장한 대상 앱에 Command-V를 보냅니다.
        let retryDelays = targetWasFrontmost ? [20] : [80, 120, 200]
        for delay in retryDelays {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return .copied }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                application.activate()
                continue
            }
            if !usePasteShortcut, let element = focusedElement(for: target.processIdentifier),
               insertDirectly(text, into: element) {
                logger.notice("Delivery inserted after target activation")
                return await finishDelivery(
                    .inserted,
                    pressEnter: pressEnterAfterPaste,
                    processIdentifier: target.processIdentifier
                )
            }

            // Whisp fallback: Electron/WebView inputs need not expose an AX text role.
            // The saved target must still be frontmost before posting Command-V.
            guard copy(text) else { return .copyFailed }
            let revision = NSPasteboard.general.changeCount
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, NSPasteboard.general.changeCount == revision,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  postPasteShortcut(to: target.processIdentifier) else {
                logger.error("Delivery copied: could not create paste events")
                return .copied
            }
            logger.notice("Delivery sent Command-V to pid=\(target.processIdentifier, privacy: .public)")
            return await finishDelivery(
                .pasted,
                pressEnter: pressEnterAfterPaste,
                processIdentifier: target.processIdentifier
            )
        }

        logger.error("Delivery copied: target application did not become frontmost")
        return copy(text) ? .copied : .copyFailed
    }

    private static func finishDelivery(
        _ result: TextDeliveryResult,
        pressEnter: Bool,
        processIdentifier: pid_t
    ) async -> TextDeliveryResult {
        guard pressEnter else { return result }

        // 붙여넣기를 처리할 짧은 여유를 준 뒤 Enter를 보냅니다.
        try? await Task.sleep(for: .milliseconds(80))
        if postEnterKey(to: processIdentifier) {
            logger.notice("Delivery sent Enter to pid=\(processIdentifier, privacy: .public)")
        } else {
            logger.error("Delivery could not create Enter events")
        }
        return result
    }

    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        // Electron/WebView 앱은 실제 편집 요소를 메인 앱이 아닌 렌더러 프로세스의
        // AX 트리에 노출할 수 있습니다. 대상 앱이 앞에 있을 때는 PID가 달라도
        // 시스템이 보고하는 실제 키보드 포커스를 우선합니다.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
            let systemWideElement = AXUIElementCreateSystemWide()
            if let element = elementAttribute(kAXFocusedUIElementAttribute, from: systemWideElement),
               !belongsToCurrentProcess(element) {
                return element
            }
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        if let element = elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement),
           belongsToProcess(element, processIdentifier) {
            return element
        }
        return nil
    }

    private static func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func belongsToProcess(_ element: AXUIElement, _ processIdentifier: pid_t) -> Bool {
        var elementPID: pid_t = 0
        return AXUIElementGetPid(element, &elementPID) == .success && elementPID == processIdentifier
    }

    private static func belongsToCurrentProcess(_ element: AXUIElement) -> Bool {
        belongsToProcess(element, ProcessInfo.processInfo.processIdentifier)
    }

    private static func insertDirectly(_ text: String, into element: AXUIElement) -> Bool {
        if isAttributeSettable(kAXSelectedTextAttribute, on: element),
           AXUIElementSetAttributeValue(
               element,
               kAXSelectedTextAttribute as CFString,
               text as CFString
           ) == .success {
            return true
        }

        return replaceValueAtSelectedRange(text, in: element)
    }

    private static func replaceValueAtSelectedRange(_ text: String, in element: AXUIElement) -> Bool {
        guard isAttributeSettable(kAXValueAttribute, on: element),
              let currentValue = attribute(kAXValueAttribute, from: element) as? String,
              let rangeReference = attribute(kAXSelectedTextRangeAttribute, from: element),
              CFGetTypeID(rangeReference) == AXValueGetTypeID()
        else { return false }

        let rangeValue = unsafeBitCast(rangeReference, to: AXValue.self)
        var selectedRange = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &selectedRange)
        else { return false }

        let value = currentValue as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location + selectedRange.length <= value.length
        else { return false }

        let updatedValue = value.mutableCopy() as! NSMutableString
        updatedValue.replaceCharacters(
            in: NSRange(location: selectedRange.location, length: selectedRange.length),
            with: text
        )
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        ) == .success else { return false }

        var caretRange = CFRange(
            location: selectedRange.location + (text as NSString).length,
            length: 0
        )
        if let caretValue = AXValueCreate(.cfRange, &caretRange) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                caretValue
            )
        }
        return true
    }

    private static func attribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func postPasteShortcut(to processIdentifier: pid_t) -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }

    private static func postEnterKey(to processIdentifier: pid_t) -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return false }
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
