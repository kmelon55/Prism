import AppKit
import PrismKit
import SwiftUI

enum PermissionsPane {
    static let id = "permissions"

    @MainActor
    static func make() -> SettingsPane {
        SettingsPane(id: id, title: String(localized: "Permissions", bundle: .module), systemImage: "checkmark.shield", group: .privacy, order: 20,
                     keywords: SystemPermission.allCases.map(\.title) + SystemPermission.allCases.map(\.heading)
                         + ["Manage permission", "Current permission target"].map(SystemStrings.localized)) {
            PermissionsView()
        }
    }
}

@MainActor
@Observable
final class PermissionsModel {
    private(set) var states: [SystemPermission: SystemPermission.State] = [:]
    private(set) var runtime: PermissionRuntime?
    private(set) var pending: SystemPermission?
    private(set) var isRefreshing = false

    func state(_ permission: SystemPermission) -> SystemPermission.State? { states[permission] }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for permission in SystemPermission.allCases {
            states[permission] = await permission.currentState()
        }
    }

    func loadRuntime() async {
        guard runtime == nil else { return }
        runtime = await Task.detached(priority: .utility) { PermissionRuntime.current() }.value
    }

    func request(_ permission: SystemPermission) async {
        pending = permission
        await permission.request()
        await refresh()
        if states[permission] == .granted { pending = nil }
    }
}

/// The Tauri permissions section: a summary callout, then one group per permission with its status pill and
/// actions, and the identity of the running executable that macOS checks.
private struct PermissionsView: View {
    @ViewState private var model = PermissionsModel()

    var body: some View {
        PrismSettingsPage(String(localized: "Permissions", bundle: .module)) {
            PrismCallout(systemImage: "checkmark.shield",
                         title: Text("Native access, only when needed", bundle: .module),
                         detail: Text("Check permissions for the microphone, text insertion and modifier shortcuts.", bundle: .module))
            ForEach(SystemPermission.allCases) { permission in
                PermissionGroup(permission: permission, state: model.state(permission), isPending: model.pending == permission,
                                isRefreshing: model.isRefreshing,
                                onRequest: { Task { await model.request(permission) } },
                                onRefresh: { Task { await model.refresh() } })
            }
            if let runtime = model.runtime {
                RuntimeGroup(runtime: runtime, accessibilityGranted: model.state(.accessibility) == .granted)
            }
        }
        .task {
            await model.refresh()
            await model.loadRuntime()
        }
        .task {
            // Grants made in System Settings while this pane stays visible appear without switching apps.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct PermissionGroup: View {
    let permission: SystemPermission
    let state: SystemPermission.State?
    let isPending: Bool
    let isRefreshing: Bool
    let onRequest: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        PrismSettingsGroup(Text(verbatim: permission.title)) {
            PrismSettingsRow(Text(verbatim: permission.heading), detail: Text(verbatim: permission.purpose)) {
                if let state {
                    PrismStatusPill(label(state), tone: tone(state))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            PrismSettingsRow(Text("Manage permission", bundle: .module), detail: manageDetail, stacked: true) {
                HStack(spacing: 8) {
                    if let state, state != .granted, permission.canRequest(in: state) {
                        Button(action: onRequest) {
                            Label { Text(isPending ? "Waiting for access…" : "Request Access", bundle: .module) } icon: {
                                Image(systemName: "checkmark.shield")
                            }
                        }
                        .disabled(isPending)
                    }
                    Button { permission.openSettings() } label: {
                        Label { Text("System Settings", bundle: .module) } icon: { Image(systemName: "arrow.up.forward.square") }
                    }
                    Button(action: onRefresh) {
                        Label { Text("Check Again", bundle: .module) } icon: { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing)
                }
                .buttonStyle(.prism)
                .labelStyle(PermissionButtonLabelStyle())
            }
        }
    }

    private var manageDetail: Text? {
        switch permission {
        case .accessibility:
            Text("Ordinary shortcut combinations do not require access; single and double modifier presses require Accessibility permission.", bundle: .module)
        case .microphone:
            Text("Prism asks the first time you dictate. If you declined, allow it in System Settings.", bundle: .module)
        case .screenRecording:
            Text("macOS may ask you to reopen Prism after you allow it.", bundle: .module)
        case .automation:
            Text("Prism asks the first time it controls Finder.", bundle: .module)
        }
    }

    private func label(_ state: SystemPermission.State) -> String {
        switch state {
        case .granted: String(localized: "Allowed", bundle: .module)
        case .notDetermined: String(localized: "Not requested", bundle: .module)
        case .denied: String(localized: "Needs access", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }

    private func tone(_ state: SystemPermission.State) -> PrismStatusPill.Tone {
        switch state {
        case .granted: .success
        case .denied: .warning
        case .notDetermined, .unknown: .neutral
        }
    }
}

/// Icon and title with the Tauri button spacing.
private struct PermissionButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .medium))
            configuration.title
        }
    }
}

/// `PermissionRuntimeDetails`: which executable macOS checks, so a development build's missing access is explainable.
private struct RuntimeGroup: View {
    let runtime: PermissionRuntime
    let accessibilityGranted: Bool

    var body: some View {
        PrismSettingsGroup(Text("Current permission target", bundle: .module)) {
            VStack(alignment: .leading, spacing: 12) {
                PrismSettingsNote(Text(runtime.bundled ? "Permissions are checked for this app." : "This is a development executable. Its permissions can differ from the installed Prism.app.", bundle: .module))
                if !accessibilityGranted {
                    PrismSettingsNote(Text("An enabled Prism entry at another path does not grant this process access. Add and allow the target below. Prism checks again when you return.", bundle: .module))
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(verbatim: runtime.permissionTarget)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PrismTheme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: runtime.permissionTarget)])
                    } label: { Text("Reveal current executable", bundle: .module) }
                        .buttonStyle(.prism)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .prismSettingsCard(cornerRadius: 10)
                if runtime.adHoc {
                    PrismSettingsNote(Text("This ad-hoc build may need authorization again after a native rebuild.", bundle: .module))
                    if !accessibilityGranted {
                        PrismSettingsNote(Text("If this exact path is already enabled but was rebuilt, remove that entry and add the current executable again.", bundle: .module))
                    }
                }
                PrismDisclosure(Text("Runtime details", bundle: .module)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(runtime.identifier ?? "—") · PID \(runtime.pid)")
                        Text(verbatim: runtime.codeHash ?? "—")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PrismTheme.textMuted)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

extension SystemPermission {
    /// What the permission is for, as the row title of its group.
    var heading: String {
        switch self {
        case .accessibility: String(localized: "Window management and dictation insertion", bundle: .module)
        case .screenRecording: String(localized: "Screen capture for AI", bundle: .module)
        case .microphone: String(localized: "Dictation recording", bundle: .module)
        case .automation: String(localized: "Finder and scripts", bundle: .module)
        }
    }
}
