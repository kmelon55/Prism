import AppKit

struct NotchGeometry {
    let screenFrame: CGRect
    let cameraWidth: CGFloat
    let topInset: CGFloat
    let showsActivity: Bool

    init(screenFrame: CGRect, cameraWidth: CGFloat = 0, topInset: CGFloat = 0, showsActivity: Bool = false) {
        self.screenFrame = screenFrame
        self.cameraWidth = max(0, cameraWidth)
        self.topInset = max(0, topInset)
        self.showsActivity = showsActivity
    }

    @MainActor init(screen: NSScreen, showsActivity: Bool = false) {
        let cameraWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            cameraWidth = max(0, right.minX - left.maxX)
        } else { cameraWidth = 0 }
        self.init(screenFrame: screen.frame, cameraWidth: cameraWidth, topInset: screen.safeAreaInsets.top, showsActivity: showsActivity)
    }

    var headerHeight: CGFloat { cameraWidth > 0 ? max(24, topInset) : 26 }
    var compactWidth: CGFloat { min(screenFrame.width - 24, max(180, cameraWidth) + (showsActivity ? 132 : 20)) }
    var expandedWidth: CGFloat { min(480, screenFrame.width - 24) }

    /// Reserve the spring's small overshoot once. This window stays fixed through every transition.
    var stageFrame: CGRect {
        let width = min(screenFrame.width, expandedWidth + 32)
        let height = headerHeight + 296 + 24
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    func frame(mode: NotchPresentation.Mode) -> CGRect {
        let width = mode == .compact ? compactWidth : mode == .preview ? min(400, expandedWidth) : expandedWidth
        let contentHeight: CGFloat = mode == .expanded ? 296 : mode == .preview ? 72 : 0
        let height = headerHeight + contentHeight
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }
}
