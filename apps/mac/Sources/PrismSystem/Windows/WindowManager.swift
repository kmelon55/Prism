import AppKit
import ApplicationServices

struct WindowActionError: Error, Equatable {
    enum Code: Equatable {
        case accessibilityRequired, noTarget, windowUnavailable, noPreviousLayout, noOtherDisplay, refused, notAccepted
    }

    var code: Code
    var message: String

    static func make(_ code: Code) -> WindowActionError {
        let english = switch code {
        case .accessibilityRequired: "Allow Prism in System Settings > Privacy & Security > Accessibility, then try again."
        case .noTarget: "Open another application, then show Prism and try the window action again."
        case .windowUnavailable: "Prism could not read the focused window."
        case .noPreviousLayout: "There is no previous Prism window layout to restore for the focused window."
        case .noOtherDisplay: "Connect another display to move this window."
        case .refused: "The target application refused the requested window geometry. Confirm that the window is resizable."
        case .notAccepted: "The application did not accept this window layout."
        }
        return WindowActionError(code: code, message: SystemStrings.localized(english))
    }
}

/// The window being arranged: its owning process, Accessibility element and frame.
@MainActor
protocol ManagedWindow: AnyObject {
    var identity: WindowIdentity { get }
    func frame() throws -> CGRect
    func setSize(_ size: CGSize) throws
    func setPosition(_ point: CGPoint) throws
}

/// Applies window layouts to the focused window of the app the user was working in. Cycle and restore state
/// live only in memory, as in the Tauri app.
@MainActor
final class WindowManager {
    private let options: @MainActor () -> WindowOptions
    private let workAreas: @MainActor () -> [CGRect]
    private var previous = PreviousLayouts()
    private var cycle: CycleStep?

    init(options: @escaping @MainActor () -> WindowOptions, workAreas: @escaping @MainActor () -> [CGRect] = WindowManager.screenWorkAreas) {
        self.options = options
        self.workAreas = workAreas
    }

    /// Arranges `window`. Returns the frame the app actually accepted.
    @discardableResult
    func apply(_ layout: WindowLayout, to window: some ManagedWindow) throws(WindowActionError) -> CGRect {
        let identity = window.identity
        let current: CGRect
        do { current = try window.frame() } catch { throw .make(.windowUnavailable) }
        var areas = workAreas()
        guard !areas.isEmpty else { throw .make(.windowUnavailable) }
        areas.sort { $0.minX != $1.minX ? $0.minX < $1.minX : $0.minY < $1.minY }
        let source = WindowGeometry.displayIndex(for: current, in: areas)
        let options = options()

        if layout == .restorePreviousLayout {
            guard let remembered = previous.restoreBounds(identity) else { throw .make(.noPreviousLayout) }
            let area = areas[WindowGeometry.displayIndex(for: remembered, in: areas)]
            let actual = try write(WindowGeometry.clamp(remembered, to: area), to: window)
            previous.completeRestore(identity)
            cycle = nil
            return actual
        }

        let index = WindowGeometry.cycleIndex(previous: cycle, window: identity, layout: layout, current: current, enabled: options.cycle)
        let continuing = options.cycle && cycle.map {
            $0.window == identity && $0.layout == layout && WindowGeometry.close($0.bounds, current)
        } == true
        let target: CGRect
        if layout.isDisplayMove {
            guard areas.count > 1 else { throw .make(.noOtherDisplay) }
            let destination = layout == .nextDisplay ? (source + 1) % areas.count : (source + areas.count - 1) % areas.count
            target = WindowGeometry.transfer(current, from: areas[source], to: areas[destination])
        } else {
            target = WindowGeometry.configuredRect(layout, workArea: areas[source], current: current, options: options, cycleIndex: index)
        }

        let replaced: CGRect?? = continuing ? nil : .some(previous.remember(identity, current))
        let actual: CGRect
        do {
            actual = try write(target, to: window)
        } catch {
            // A size failure may follow a position change. Restore geometry as well as history.
            if (try? write(current, to: window)) != nil, let replaced { previous.rollback(identity, to: replaced) }
            cycle = nil
            throw error
        }
        if WindowGeometry.close(actual, current), !WindowGeometry.close(target, current) {
            if let replaced { previous.rollback(identity, to: replaced) }
            cycle = nil
            throw .make(.notAccepted)
        }
        cycle = options.cycle && layout.cycles ? CycleStep(window: identity, layout: layout, index: index, bounds: actual) : nil
        return actual
    }

    private func write(_ target: CGRect, to window: some ManagedWindow) throws(WindowActionError) -> CGRect {
        do {
            return try WindowGeometry.apply(target, read: window.frame,
                                            resize: { try window.setSize($0.size) },
                                            position: { try window.setPosition($0.origin) })
        } catch let error as WindowActionError {
            throw error
        } catch {
            throw .make(.refused)
        }
    }

    /// Visible frames of every display in Accessibility coordinates (top-left origin, y down).
    static func screenWorkAreas() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { accessibilityRect($0.visibleFrame, primaryHeight: primary.frame.height) }
    }

    /// Converts a bottom-left-origin AppKit rectangle to the top-left-origin space AX uses.
    nonisolated static func accessibilityRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The focused window of an application, through the Accessibility API.
@MainActor
final class AccessibilityWindow: ManagedWindow {
    let identity: WindowIdentity
    private let element: AXUIElement

    /// The focused (or main) window of `application`. Requires Accessibility permission.
    init(application: NSRunningApplication) throws(WindowActionError) {
        guard AXIsProcessTrusted() else { throw .make(.accessibilityRequired) }
        let pid = application.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        var value: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        if status != .success || value == nil {
            status = AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value)
        }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw .make(.windowUnavailable)
        }
        element = value as! AXUIElement
        // Equal AX elements for the same window hash equally across separate lookups.
        identity = WindowIdentity(pid: pid, element: CFHash(element))
    }

    func frame() throws -> CGRect {
        var point = CGPoint.zero
        var size = CGSize.zero
        guard read(kAXPositionAttribute, type: .cgPoint, into: &point),
              read(kAXSizeAttribute, type: .cgSize, into: &size) else { throw WindowActionError.make(.windowUnavailable) }
        return CGRect(origin: point, size: size)
    }

    func setSize(_ size: CGSize) throws {
        var size = size
        try write(kAXSizeAttribute, value: AXValueCreate(.cgSize, &size))
    }

    func setPosition(_ point: CGPoint) throws {
        var point = point
        try write(kAXPositionAttribute, value: AXValueCreate(.cgPoint, &point))
    }

    private func read<T: BitwiseCopyable>(_ attribute: String, type: AXValueType, into result: inout T) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        return AXValueGetValue(value as! AXValue, type, &result)
    }

    private func write(_ attribute: String, value: AXValue?) throws {
        guard let value, AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success else {
            throw WindowActionError.make(.refused)
        }
    }
}
