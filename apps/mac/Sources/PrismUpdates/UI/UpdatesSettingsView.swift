import PrismKit
import SwiftUI

/// The Updates group at the top of Settings → General: version and status with the one main action (check, install
/// or restart), error details and the automatic-installation opt-in. Mirrors `Updates.tsx`; the General pane hosts
/// it inside its `PrismSettingsPage`, so this view draws rows only.
struct UpdatesSettingsView: View {
    let controller: UpdateController
    @ViewState private var busy = false
    @ViewState private var failure: String?

    var body: some View {
        let status = controller.status
        PrismSettingsGroup {
            PrismSettingsRow(Text(verbatim: status.currentTitle + (status.version.map { " → \($0)" } ?? "")),
                             detail: detail(status)) {
                HStack(spacing: 8) {
                    if status.phase == .checking || status.phase == .installing {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                    }
                    actionButton(status)
                }
            }
            if let error = status.error {
                PrismDisclosure(Text("Error details", bundle: .module)) {
                    Text(verbatim: error)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 8)
            }
            PrismSettingsRow(Text("Install updates automatically", bundle: .module),
                             detail: Text("Download and install new versions in the background. Changes take effect when you restart Prism.", bundle: .module)) {
                Toggle(isOn: Binding(get: { status.automaticInstall }, set: setAutomatic)) { EmptyView() }
                    .toggleStyle(.prism)
                    .labelsHidden()
                    .disabled(isDisabled(status))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Prism updates", bundle: .module))
    }

    /// The status line, and the failure of the last button press under it (`role="alert"` in `Updates.tsx`).
    private func detail(_ status: UpdateStatus) -> Text {
        let label = Text(verbatim: UpdateStrings.label(for: status))
        guard let failure else { return label }
        return label + Text(verbatim: "\n") + Text(verbatim: failure).foregroundColor(PrismTheme.danger)
    }

    /// One main action, as in Tauri: install (or retry) and restart are primary, checking is secondary.
    @ViewBuilder
    private func actionButton(_ status: UpdateStatus) -> some View {
        let label = Label {
            Text(verbatim: UpdateStrings.actionTitle(for: status))
        } icon: {
            Image(systemName: status.canInstall ? "arrow.down.circle" : "arrow.clockwise")
        }
        if status.canInstall || status.phase == .installed {
            Button { run(status) } label: { label }
                .buttonStyle(.prismPrimary)
                .disabled(isDisabled(status))
        } else {
            Button { run(status) } label: { label }
                .buttonStyle(.prism)
                .disabled(isDisabled(status))
        }
    }

    private func isDisabled(_ status: UpdateStatus) -> Bool {
        busy || [.checking, .installing, .development].contains(status.phase)
    }

    private func run(_ status: UpdateStatus) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                if status.canInstall {
                    try await controller.install()
                } else if status.phase == .installed {
                    try controller.restart()
                } else {
                    try await controller.check()
                }
            } catch {
                failure = String(localized: "Could not update Prism. Check your connection and try again.", bundle: .module)
            }
        }
    }

    private func setAutomatic(_ enabled: Bool) {
        failure = nil
        do {
            try controller.setAutomaticInstall(enabled)
        } catch {
            failure = String(localized: "Could not save update settings.", bundle: .module)
        }
    }
}
