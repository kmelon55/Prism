import AppKit
import QuartzCore
import SwiftUI

extension NotchFeature {
    /// Uses the same canvas, mask animation and SwiftUI content as the installed app, in an invisible
    /// window. Each PNG samples Core Animation's presentation path, not a separate animation mockup.
    @MainActor
    public static func renderMotionSnapshots(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = NotchModel(widgets: [], initial: NotchPreferences()) { _ in }
        let geometry = NotchGeometry(screenFrame: CGRect(x: -20_000, y: -20_000, width: 1512, height: 982), cameraWidth: 180, topInset: 34)
        let window = NSPanel(contentRect: geometry.stageFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let canvas = NotchCanvas(frame: CGRect(origin: .zero, size: geometry.stageFrame.size))
        window.contentView = canvas
        window.orderFrontRegardless()
        defer { canvas.clear(); window.orderOut(nil) }
        func present(_ mode: NotchPresentation.Mode, animated: Bool) {
            canvas.present(AnyView(NotchView(model: model, geometry: geometry, mode: mode)),
                           size: geometry.frame(mode: mode).size, mode: mode, animated: animated)
            CATransaction.flush()
        }
        var measurements: [[String: Any]] = []
        func sample(_ name: String, began: TimeInterval) throws {
            let size = canvas.visibleSize, content = canvas.contentFrame ?? .zero
            measurements.append(["frame": name, "elapsed": CACurrentMediaTime() - began,
                                 "outlineWidth": size.width, "outlineHeight": size.height,
                                 "contentWidth": content.width, "contentHeight": content.height,
                                 "contentX": content.minX, "contentY": content.minY,
                                 "contentOpacity": canvas.contentOpacity,
                                 "windowWidth": window.frame.width, "windowHeight": window.frame.height])
            try canvas.renderPresentation(to: directory.appending(path: name + ".png"))
        }
        present(.expanded, animated: true)
        let firstAppearance = CACurrentMediaTime()
        for time in [0.016, 0.06, 0.12, 0.20, 0.34, 0.60] {
            let remaining = time - (CACurrentMediaTime() - firstAppearance)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try sample("first-\(Int(time * 1000))", began: firstAppearance)
        }
        canvas.clear()
        present(.compact, animated: false)
        try await Task.sleep(for: .milliseconds(150))
        for (name, mode) in [("open", NotchPresentation.Mode.expanded), ("close", .compact)] {
            present(mode, animated: true)
            let began = CACurrentMediaTime()
            for time in [0.016, 0.06, 0.12, 0.20, 0.34, 0.60] {
                let remaining = time - (CACurrentMediaTime() - began)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                try sample("\(name)-\(Int(time * 1000))", began: began)
            }
        }
        present(.expanded, animated: true)
        try await Task.sleep(for: .milliseconds(80))
        present(.compact, animated: true)
        let reversed = CACurrentMediaTime()
        for time in [0.016, 0.08, 0.20, 0.60] {
            let remaining = time - (CACurrentMediaTime() - reversed)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try sample("reverse-\(Int(time * 1000))", began: reversed)
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "measurements.json"))
    }
}
