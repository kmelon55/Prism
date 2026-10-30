import AppKit
import PrismKit
import ServiceManagement
import SwiftUI

/// "Launch at login" for the General settings pane, as one `PrismSettingsRow`.
///
/// It reflects `SMAppService.mainApp`, refreshes when Prism becomes active (after the user visits Login Items),
/// and is disabled outside the installed app in /Applications.
public struct LaunchAtLoginToggle: View {
    @ViewState private var model = LaunchAtLoginModel()

    public init() {}

    public var body: some View {
        PrismSettingsRow(Text("Launch at login", bundle: .module), detail: detail) {
            HStack(spacing: 8) {
                if model.status == .requiresApproval {
                    Button { model.openLoginItems() } label: { Text("Open Login Items", bundle: .module) }
                        .buttonStyle(.prism)
                }
                if model.error != nil {
                    Button { model.refresh() } label: { Text("Refresh", bundle: .module) }
                        .buttonStyle(.prism)
                }
                Toggle(isOn: Binding(get: { model.status?.isOn ?? false }, set: { model.set($0) })) { EmptyView() }
                    .toggleStyle(.prism)
                    .labelsHidden()
                    .disabled(model.isBusy || model.status == nil || model.status == .unsupported)
            }
            .disabled(model.isBusy)
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var detail: Text {
        if let error = model.error { return Text(verbatim: error).foregroundColor(PrismTheme.danger) }
        return Text(verbatim: model.status?.description ?? String(localized: "Checking login item settings…", bundle: .module))
    }
}

@MainActor
@Observable
final class LaunchAtLoginModel {
    private(set) var status: LoginItemStatus?
    private(set) var isBusy = false
    private(set) var error: String?

    private let service: any LoginItemService
    private let installed: Bool

    init(service: any LoginItemService = SMAppService.mainApp, installed: Bool = LoginItem.isInstalledApp()) {
        self.service = service
        self.installed = installed
    }

    func refresh() {
        guard !isBusy else { return }
        status = LoginItem.status(service: service, installed: installed)
    }

    func set(_ enabled: Bool) {
        guard !isBusy, let status, status != .unsupported else { return }
        isBusy = true
        error = nil
        do {
            try LoginItem.set(enabled, service: service)
        } catch {
            self.error = String(localized: "Could not change login item settings. Try again.", bundle: .module)
        }
        self.status = LoginItem.status(service: service, installed: installed)
        isBusy = false
    }

    func openLoginItems() {
        LoginItem.openSystemSettings()
    }
}
