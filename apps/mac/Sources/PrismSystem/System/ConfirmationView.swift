import PrismKit
import SwiftUI

/// An in-palette confirmation for session-ending or irreversible actions. Return confirms; Escape (handled by the
/// palette) returns to the results and leaves the palette open, like cancelling the Tauri dialog.
struct ConfirmationView: View {
    let systemImage: String
    let title: String
    let message: String
    let confirmTitle: String
    var detail: [String] = []
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PrismScreenHeader(height: PrismPaletteMetrics.searchHeight) {
                PrismBackButton(help: Text("Cancel", bundle: .module), action: onCancel)
                Text(verbatim: title)
                    .font(.prism(15, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                Spacer()
            }
            VStack(spacing: 10) {
                Image(systemName: PrismGlyph.outline(systemImage))
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(PrismTheme.danger)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(PrismTheme.surfaceStrong))
                    .overlay(Circle().strokeBorder(PrismTheme.lineStrong))
                Text(verbatim: title)
                    .font(.prism(15, weight: 600))
                    .foregroundStyle(PrismTheme.text)
                    .padding(.top, 6)
                Text(verbatim: message)
                    .font(.prism(12))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
                if !detail.isEmpty {
                    Text(verbatim: detail.formatted(.list(type: .and)))
                        .font(.prism(11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 460)
                }
                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        HStack(spacing: 6) {
                            Text("Cancel", bundle: .module)
                            KeyCap("esc")
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.prism)
                    Button(action: onConfirm) {
                        HStack(spacing: 6) {
                            Text(verbatim: confirmTitle)
                            KeyCap("↵")
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.prismDestructive)
                }
                .padding(.top, 12)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.return) {
            onConfirm()
            return .handled
        }
    }
}
