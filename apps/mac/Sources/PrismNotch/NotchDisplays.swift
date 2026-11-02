import AppKit
import Observation

struct NotchDisplay: Identifiable, Equatable {
    let id: String
    let number: UInt32
    let name: String
    let frame: CGRect
    var cameraWidth: CGFloat = 0
    var topInset: CGFloat = 0
    var isBuiltIn = false
    var isMain = false

    var hasCameraCutout: Bool { cameraWidth > 0 && topInset > 0 }

    /// A simulated notch belongs to ordinary desktop Spaces, not another app's full-screen Space.
    /// Use the actual cutout, not whether the display is built in (older MacBooks have no notch).
    var collectionBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .stationary, .ignoresCycle,
         hasCameraCutout ? .fullScreenAuxiliary : .fullScreenNone]
    }

    var target: NotchDisplayTarget { NotchDisplayTarget(id: id, name: name) }
    func geometry(active: Bool) -> NotchGeometry {
        NotchGeometry(screenFrame: frame, cameraWidth: cameraWidth, topInset: topInset, showsActivity: active)
    }

    @MainActor static func connected() -> [Self] {
        var frames: [CGRect] = []
        return NSScreen.screens.compactMap { screen in
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  !frames.contains(screen.frame) else { return nil }
            // Mirrored displays share a desktop: never stack two panels at the same location.
            frames.append(screen.frame)
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "legacy:\(number)"
            let geometry = NotchGeometry(screen: screen)
            return Self(id: id, number: number, name: screen.localizedName, frame: screen.frame,
                        cameraWidth: geometry.cameraWidth, topInset: geometry.topInset,
                        isBuiltIn: CGDisplayIsBuiltin(number) != 0, isMain: number == CGMainDisplayID())
        }
    }
}

struct NotchDisplayTarget: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    func matches(_ display: NotchDisplay) -> Bool { id == display.id || id == "legacy:\(display.number)" }
}

struct NotchDisplays: Codable, Equatable {
    enum Mode: String, Codable { case main, all, selected }
    var mode = Mode.main
    var targets: [NotchDisplayTarget] = []

    func resolve(in connected: [NotchDisplay]) -> [NotchDisplay] {
        switch mode {
        case .main: return (connected.first(where: \.isMain) ?? connected.first).map { [$0] } ?? []
        case .all: return connected
        case .selected: return connected.filter { display in targets.contains { $0.matches(display) } }
        }
    }

    mutating func set(_ display: NotchDisplayTarget, selected: Bool, connected: [NotchDisplay]) {
        if mode != .selected { targets = resolve(in: connected).map(\.target) }
        mode = .selected
        targets.removeAll { $0.id == display.id }
        if selected { targets.append(display) }
    }

    var isValid: Bool { Set(targets.map(\.id)).count == targets.count && targets.allSatisfy { !$0.id.isEmpty } }
}

/// Presentation belongs to a display; the model's timer and feature-owned data remain shared.
@MainActor @Observable
final class NotchDisplaySession {
    var presentation = NotchPresentation()
    var selection = "timer"
}
