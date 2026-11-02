import PrismKit
import SwiftUI

struct DictationNotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let service: DictationService
    let dismiss: () -> Void
    let settings: () -> Void
    private var controller: DictationController { service.controller }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label(Self.title(controller.phase), systemImage: controller.phase == .recording ? "record.circle" : "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(controller.phase == .recording ? .orange : .secondary)
                Spacer()
                NotchIconButton("gearshape", label: String(localized: "Dictation Settings", bundle: .module), action: settings)
            }
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(.orange.opacity(0.035)).frame(width: 82, height: 82)
                    Circle().fill(.orange.opacity(0.08)).frame(width: 64, height: 64)
                    Image(systemName: controller.phase == .error ? "exclamationmark" : "mic.fill")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if controller.busy {
                        WaveformView(amplitude: controller.amplitude, phase: controller.phase)
                            .frame(maxWidth: .infinity).frame(height: 34).foregroundStyle(.orange)
                    } else {
                        Text("Speak naturally.", bundle: .module).font(.system(size: 18, weight: .medium))
                    }
                    if !controller.message.isEmpty, controller.phase == .error {
                        Text(verbatim: controller.message).foregroundStyle(.red).font(.system(size: 11)).lineLimit(3)
                    } else {
                        Text("Speak into the app you were using.", bundle: .module)
                            .foregroundStyle(.secondary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if !controller.busy || controller.phase == .recording {
                    Button {
                        dismiss()
                        service.toggle(promptMode: false)
                    } label: {
                        Label(controller.phase == .recording ? String(localized: "Finish Dictation", bundle: .module) : String(localized: "Start Dictation", bundle: .module),
                              systemImage: controller.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 36)
                    }.buttonStyle(NotchButtonStyle(prominent: true))
                }
                if controller.busy {
                    Button { controller.cancel() } label: {
                        Text("Cancel", bundle: .module).font(.system(size: 11)).padding(.horizontal, 14).frame(height: 36)
                    }.buttonStyle(NotchButtonStyle())
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controller.phase)
    }

    static func title(_ phase: DictationPhase) -> String {
        let value: String
        switch phase {
        case .recording: value = "Recording"
        case .preparing: value = "Preparing…"
        case .transcribing: value = "Transcribing…"
        case .processing: value = "Processing…"
        case .inserting: value = "Inserting…"
        case .error: value = "Dictation needs attention"
        case .idle, .preview: value = "Ready to listen"
        }
        return String(localized: String.LocalizationValue(value), bundle: .module)
    }
}

/// Observes the controller in its own view, so audio samples never rebuild the notch window or tabs.
struct DictationCompactView: View {
    let controller: DictationController

    var body: some View {
        WaveformView(amplitude: controller.amplitude, phase: controller.phase, barCount: 9)
            .foregroundStyle(.orange)
            .accessibilityLabel(DictationNotchView.title(controller.phase))
    }
}
