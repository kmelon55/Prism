// Reused from Whisp. MIT; see LICENSE-Whisp.
import Foundation

struct ModifierDoubleTapDetector {
    private(set) var isPressed = false
    private var firstReleaseTime: TimeInterval?
    private let maximumInterval: TimeInterval

    init(maximumInterval: TimeInterval = 0.42) {
        self.maximumInterval = maximumInterval
    }

    mutating func handle(
        modifierDown: Bool,
        hasOtherModifiers: Bool,
        isKeyDown: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        if isKeyDown || hasOtherModifiers {
            reset()
            return false
        }

        if modifierDown {
            guard !isPressed else { return false }
            isPressed = true
            if let firstReleaseTime, timestamp - firstReleaseTime <= maximumInterval {
                reset()
                return true
            }
            if let firstReleaseTime, timestamp - firstReleaseTime > maximumInterval {
                self.firstReleaseTime = nil
            }
            return false
        }

        guard isPressed else { return false }
        isPressed = false
        firstReleaseTime = timestamp
        return false
    }

    mutating func reset() {
        isPressed = false
        firstReleaseTime = nil
    }
}
