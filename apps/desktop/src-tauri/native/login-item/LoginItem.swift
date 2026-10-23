import Foundation
import ServiceManagement

// Injectable service seam: tests never change the host's login items.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
extension SMAppService: LoginItemService {}

func setLoginItem(_ enabled: Bool, service: LoginItemService) throws {
    if enabled {
        // Approval is a user action in System Settings, not repeated registration.
        guard service.status != .enabled && service.status != .requiresApproval else { return }
        do { try service.register() }
        catch {
            // macOS may report launch-denied after successfully registering.
            guard service.status == .requiresApproval else { throw error }
        }
    } else if service.status != .notRegistered {
        try service.unregister()
    }
}

private var isInstalledApp: Bool {
    Bundle.main.bundleIdentifier == "dev.prism.desktop"
        && Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Prism.app"
}

@_cdecl("prism_login_item_status")
func prismLoginItemStatus() -> Int32 {
    guard isInstalledApp else { return -1 }
    switch SMAppService.mainApp.status {
    case .notRegistered: return 0
    case .enabled: return 1
    case .requiresApproval: return 2
    case .notFound: return 3
    @unknown default: return 3
    }
}

// The caller frees the strdup result. A nil result means success.
@_cdecl("prism_set_login_item")
func prismSetLoginItem(_ enabled: Bool) -> UnsafeMutablePointer<CChar>? {
    guard isInstalledApp else { return strdup("Install Prism in Applications to change login items.") }
    do {
        try setLoginItem(enabled, service: SMAppService.mainApp)
        return nil
    } catch { return strdup(error.localizedDescription) }
}

@_cdecl("prism_open_login_item_settings")
func prismOpenLoginItemSettings() {
    SMAppService.openSystemSettingsLoginItems()
}
