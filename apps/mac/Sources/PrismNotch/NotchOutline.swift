import SwiftUI

/// A cutout hanging from the display edge. The concave shoulders meet that edge horizontally;
/// the lower corners turn back into the sides. Size changes keep the same path topology.
struct NotchOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let growth = min(1, max(0, (rect.height - 26) / 100))
        let shoulder = min(rect.height / 2, rect.width / 8, 5 + 7 * growth)
        let bottom = min(rect.height / 2, 9 + 15 * growth)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder),
                          control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
