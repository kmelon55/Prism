// Ported from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import AppKit
import SwiftUI

struct DictationOverlayView: View {
    let controller: DictationController
    let message: String?
    let usesNativeGlass: Bool

    var body: some View {
        Group {
            if usesNativeGlass {
                content
                    .background { GlassOpticsLayer() }
                    .overlay { GlassEdgeLayer() }
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .background { GlassOpticsLayer() }
                    .overlay { GlassEdgeLayer() }
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            }
        }
        .padding(usesNativeGlass ? 0 : 12)
    }

    @ViewBuilder
    private var content: some View {
        let phase = controller.displayedPhase
        if let message {
            HStack(spacing: 10) {
                Image(systemName: controller.phase == .error ? "mic.slash.fill" : "doc.on.clipboard.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(controller.phase == .error ? Color.orange : Color.accentColor)
                Text(verbatim: message)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: 330, height: 58)
        } else {
            switch phase {
            case .recording where controller.showRecordingShortcutHints:
                let hints = controller.recordingHints
                HStack(spacing: 12) {
                    WaveformView(amplitude: controller.amplitude, phase: phase).frame(width: 96, height: 25)
                    Divider().frame(height: 20).opacity(0.45)
                    ForEach(hints) { hint in RecordingKeyHint(key: hint.key, label: hint.label) }
                }
                .padding(.horizontal, 16)
                .frame(width: min(440, 150 + CGFloat(hints.count) * 90), height: 50)
            case .transcribing where controller.showTranscriptionStatus, .processing where controller.showTranscriptionStatus:
                HStack(spacing: 12) {
                    WaveformView(amplitude: 0, phase: phase).frame(width: 72, height: 23)
                    Text(statusText(phase))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .frame(width: 220, height: 50)
            default:
                WaveformView(amplitude: phase == .recording ? controller.amplitude : 0, phase: phase)
                    .frame(width: 116, height: 25)
                    .padding(.horizontal, 24)
                    .frame(width: 164, height: 50)
            }
        }
    }

    private func statusText(_ phase: DictationPhase) -> String {
        guard phase == .processing else { return String(localized: "Transcribing…", bundle: .module) }
        return controller.processingMode == .prompt
            ? String(localized: "Structuring prompt…", bundle: .module)
            : String(localized: "Refining…", bundle: .module)
    }
}

private struct RecordingKeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: key)
                .font(.system(size: key.count > 1 ? 9 : 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, key.count > 1 ? 5 : 6)
                .frame(height: 20)
                .background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.12), lineWidth: 0.5) }
            Text(verbatim: label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Keeps the native glass refraction and only lightly reinforces the lit surface. No solid translucent fill,
/// so content behind the capsule does not turn into a grey blur.
private struct GlassOpticsLayer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            GeometryReader { geometry in
                let lighting = GlassLighting.current
                Capsule()
                    .fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.045), location: 0),
                        .init(color: .white.opacity(0.008), location: 0.34),
                        .init(color: .clear, location: 0.62),
                        .init(color: .black.opacity(0.012), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Capsule().fill(RadialGradient(colors: [.white.opacity(0.105), .white.opacity(0.025), .clear], center: lighting.point,
                                                      startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.56))
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Uses the pointer as a virtual light source, so the reflection follows it along the edge. Dispersion appears
/// only around the brightest highlight, not as a fixed rim.
private struct GlassEdgeLayer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let lighting = GlassLighting.current
            ZStack {
                Capsule().strokeBorder(.white.opacity(0.19), lineWidth: 0.55)
                Capsule()
                    .inset(by: 0.45)
                    .strokeBorder(AngularGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.065),
                        .init(color: .cyan.opacity(0.24), location: 0.095),
                        .init(color: .white.opacity(0.88), location: 0.12),
                        .init(color: .pink.opacity(0.18), location: 0.145),
                        .init(color: .clear, location: 0.205),
                        .init(color: .clear, location: 0.57),
                        .init(color: .white.opacity(0.22), location: 0.62),
                        .init(color: .clear, location: 0.69),
                        .init(color: .clear, location: 1),
                    ], center: .center, angle: lighting.angle), lineWidth: 1.05)
                    .blendMode(.screen)
                Capsule()
                    .inset(by: 1.35)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.025)],
                                                 startPoint: lighting.point, endPoint: lighting.oppositePoint), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GlassLighting {
    let point: UnitPoint
    let oppositePoint: UnitPoint
    let angle: Angle

    @MainActor
    static var current: GlassLighting {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let normalizedX = frame.width > 0 ? (mouse.x - frame.minX) / frame.width : 0.5
        let normalizedY = frame.height > 0 ? 1 - (mouse.y - frame.minY) / frame.height : 0.25
        let x = min(0.88, max(0.12, normalizedX))
        let y = min(0.72, max(0.08, normalizedY))
        return GlassLighting(point: UnitPoint(x: x, y: y), oppositePoint: UnitPoint(x: 1 - x, y: 1 - y), angle: .radians(atan2(y - 0.5, x - 0.5)))
    }
}
