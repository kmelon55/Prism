// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import SwiftUI

struct WaveformView: View {
    let amplitude: Double
    let phase: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 45)) { context in
            Canvas { canvas, size in
                let bars = 21
                let spacing: CGFloat = 3.25
                let width = (size.width - CGFloat(bars - 1) * spacing) / CGFloat(bars)
                let time = context.date.timeIntervalSinceReferenceDate
                // 실제 마이크 레벨은 낮은 구간에 오래 머무르므로 완만한 곡선으로
                // 중간 음량을 끌어올려 말할 때 높이 변화가 눈에 보이게 합니다.
                let responsiveAmplitude = pow(max(0, amplitude), 0.72)
                let isRecording = phase == "recording"
                let isTranscribing = phase == "transcribing"
                let loadingPulse = (sin(time * 3.8) + 1) / 2
                let energy = isRecording
                    ? min(0.90, max(0.13, responsiveAmplitude * 1.35))
                    : isTranscribing ? 0.34 + loadingPulse * 0.10 : 0.035
                let speed = isRecording ? 6.2 : isTranscribing ? 5.2 : 2.1

                for index in 0..<bars {
                    let x = CGFloat(index) * (width + spacing)
                    let normalizedPosition = abs((Double(index) / Double(bars - 1)) * 2 - 1)
                    let envelope = 0.62 + (1 - normalizedPosition) * 0.38
                    let primary = (sin(Double(index) * 0.76 + time * speed) + 1) / 2
                    let secondary = (sin(Double(index) * 0.31 - time * speed * 0.58) + 1) / 2
                    let motion = 0.50 + primary * 0.36 + secondary * 0.14
                    let loadingSweep = (sin(Double(index) * 0.56 - time * 5.4) + 1) / 2
                    let barEnergy = isTranscribing ? 0.13 + loadingSweep * 0.62 : energy
                    let activeHeight = size.height * CGFloat(0.10 + barEnergy * 0.86)
                    let height = max(isRecording ? 3.8 : 2.6, activeHeight * CGFloat(envelope * motion))
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: max(2, width), height: height)
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: width / 2),
                        with: .color(isTranscribing
                            ? Color.accentColor.opacity(0.76)
                            : Color.primary.opacity(isRecording ? 0.92 : 0.38))
                    )
                }
            }
        }
        .animation(.smooth(duration: 0.16), value: amplitude)
        .animation(.easeOut(duration: 0.22), value: phase)
        .accessibilityLabel(phase)
    }

}
