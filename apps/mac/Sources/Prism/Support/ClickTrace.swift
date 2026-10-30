import AppKit

/// Diagnostics for clicks that do not reach controls. Launch with `-PrismTraceClicksFile <path>` (argument domain
/// only) to append every mouse down/up Prism receives, the window and view it hits, and Prism's windows.
@MainActor
enum ClickTrace {
    private static var monitor: Any?
    private static var handle: FileHandle?

    static func startIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "PrismTraceClicksFile") else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        write("start active=\(NSApp.isActive)")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { event in
            record(event)
            return event
        }
    }

    private static func record(_ event: NSEvent) {
        var line = "\(event.type == .leftMouseDown ? "down" : event.type == .leftMouseUp ? "up" : "right")"
        line += " active=\(NSApp.isActive) clicks=\(event.clickCount)"
        if let window = event.window {
            line += " window=\(type(of: window)) '\(window.title)' key=\(window.isKeyWindow) level=\(window.level.rawValue)"
            let point = event.locationInWindow
            line += " at=(\(Int(point.x)),\(Int(point.y)))"
            if let content = window.contentView, let superview = content.superview {
                var chain: [String] = []
                var view = superview.hitTest(point)
                while let current = view, chain.count < 8 {
                    chain.append(String(describing: type(of: current)))
                    view = current.superview
                }
                line += " hit=" + chain.joined(separator: " < ")
            }
        } else {
            line += " window=nil"
        }
        write(line)
        if event.type == .leftMouseDown {
            for window in NSApp.windows where window.isVisible {
                write("  visible \(type(of: window)) '\(window.title)' frame=\(window.frame) level=\(window.level.rawValue) "
                      + "alpha=\(window.alphaValue) ignoresMouse=\(window.ignoresMouseEvents) key=\(window.isKeyWindow)")
            }
        }
    }

    private static func write(_ line: String) {
        handle?.write(Data("\(Date().timeIntervalSince1970) \(line)\n".utf8))
    }
}
