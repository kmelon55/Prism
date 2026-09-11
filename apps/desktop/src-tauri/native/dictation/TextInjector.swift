// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import AppKit
import ApplicationServices
import OSLog

struct TextInsertionTarget {
    let processIdentifier: pid_t
    let focusedElement: AXUIElement?
    let application: NSRunningApplication
}

struct TextInsertionExpectation {
    let original: String
    let expected: String

    init?(value: String, range: CFRange, text: String) {
        let original = value as NSString
        guard range.location >= 0, range.length >= 0,
              range.location <= original.length,
              range.length <= original.length - range.location else { return nil }
        self.original = value
        expected = original.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }

    func confirms(_ value: String?) -> Bool {
        // An unchanged AX value is not evidence that the app accepted an insertion.
        expected != original && value == expected
    }
}

enum TextDeliveryResult: Equatable {
    case inserted
    case pasted
    case pasteSent
    case copied
    case permissionRequired
    case copyFailed
    case unverified
    case sendFailed

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
        case .unverified:
            return language.text(
                "입력 완료를 확인하지 못했어요. 텍스트는 클립보드에 복사했어요.",
                "Could not confirm insertion. The text is on the clipboard."
            )
        case .sendFailed:
            return language.text(
                "자동 전송에 실패했어요. 텍스트는 클립보드에 복사했어요.",
                "Could not send automatically. The text is on the clipboard."
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

    struct Environment {
        var running: @MainActor (NSRunningApplication) -> Bool = { !$0.isTerminated }
        var permission: @MainActor () -> Bool = { TextInjector.hasAccessibilityPermission }
        var frontmostPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var activate: @MainActor (NSRunningApplication) -> Void = { $0.activate() }
        var focused: @MainActor (pid_t) -> AXUIElement? = { TextInjector.focusedElement(for: $0) }
        var paste: @MainActor (pid_t) -> Bool = { TextInjector.postPasteShortcut(to: $0) }
        var enter: @MainActor (pid_t) -> Bool = { TextInjector.postEnterKey(to: $0) }
        var revision: @MainActor () -> Int = { NSPasteboard.general.changeCount }
    }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        copy(text, to: .general)
    }

    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        // Normal text participates in the user's opt-in clipboard history.
        return pasteboard.writeObjects([item]) && pasteboard.string(forType: .string) == text
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
        target: TextInsertionTarget?,
        copyText: @MainActor (String) -> Bool = TextInjector.copy,
        environment: Environment = Environment()
    ) async -> TextDeliveryResult {
        guard !Task.isCancelled else { return .copied }
        // Preserve every result before trying AX or keyboard delivery. An app can
        // acknowledge an AX write or receive Command-V without accepting the text.
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

        let application = target.application

        let targetWasFrontmost = environment.frontmostPID()
            == target.processIdentifier
        if !targetWasFrontmost {
            environment.activate(application)
        }

        // 브라우저와 Electron 앱은 활성화 직후 AX 포커스를 늦게 복원할 수 있습니다.
        // AX 삽입이 지원되지 않아도 저장한 대상 앱에 Command-V를 보냅니다.
        let retryDelays = targetWasFrontmost ? [20] : [80, 120, 200]
        for delay in retryDelays {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return .copied }
            guard environment.frontmostPID() == target.processIdentifier else {
                environment.activate(application)
                continue
            }
            let element = environment.focused(target.processIdentifier)
            // Whisp fallback: Electron/WebView inputs need not expose an AX text role.
            // The saved target must still be frontmost before posting Command-V.
            guard copyText(text) else { return .copyFailed }
            // AX absence does not mean keyboard focus is absent. In particular,
            // terminals expose hidden textareas whose values do not track pasted input.
            let expectation = target.application.bundleIdentifier == "com.stablyai.orca"
                ? nil : element.flatMap { insertionExpectation(text, in: $0) }
            let revision = environment.revision()
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return .copied }
            guard environment.revision() == revision,
                  environment.frontmostPID() == target.processIdentifier,
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
            logger.notice("Paste observation: observable=\(expectation != nil, privacy: .public), confirmed=\(confirmed, privacy: .public)")
            return await finishDelivery(
                pasteResult(observable: expectation != nil, confirmed: confirmed),
                pressEnter: pressEnterAfterPaste,
                processIdentifier: target.processIdentifier,
                environment: environment
            )
        }

        logger.error("Delivery copied: target application did not become frontmost")
        return copyText(text) ? .copied : .copyFailed
    }

    private static func finishDelivery(
        _ result: TextDeliveryResult,
        pressEnter: Bool,
        processIdentifier: pid_t,
        environment: Environment
    ) async -> TextDeliveryResult {
        guard pressEnter, result.enteredInTargetApp || result == .pasteSent else { return result }

        // 붙여넣기를 처리할 짧은 여유를 준 뒤 Enter를 보냅니다.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return result }
        if environment.frontmostPID() == processIdentifier,
           environment.enter(processIdentifier) {
            logger.notice("Delivery sent Enter to pid=\(processIdentifier, privacy: .public)")
        } else {
            logger.error("Delivery could not create Enter events")
            return .sendFailed
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

    static func pasteResult(observable: Bool, confirmed: Bool) -> TextDeliveryResult {
        confirmed ? .pasted : (observable ? .unverified : .pasteSent)
    }

    private static func insertionExpectation(_ text: String, in element: AXUIElement) -> TextInsertionExpectation? {
        guard let value = attribute(kAXValueAttribute, from: element) as? String,
              let reference = attribute(kAXSelectedTextRangeAttribute, from: element),
              CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeBitCast(reference, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return TextInsertionExpectation(value: value, range: range, text: text)
    }

    private static func attribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
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
