import Foundation
import ServiceManagement

/// Injectable service seam: tests never change the host's login items.
@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Ported from `LoginItem.swift` and `login_item.rs`.
enum LoginItemStatus: Equatable, Sendable {
    /// A development build or an app outside /Applications; it must never register itself.
    case unsupported
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        default: self = .notFound
        }
    }

    /// The switch shows on for both enabled and waiting-for-approval, so turning it off unregisters.
    var isOn: Bool { self == .enabled || self == .requiresApproval }

    var description: String {
        switch self {
        case .unsupported: String(localized: "Available in the installed macOS app in Applications.", bundle: .module)
        case .notRegistered: String(localized: "Start Prism in the background when you sign in to your Mac.", bundle: .module)
        case .enabled: String(localized: "Prism will start in the background when you sign in.", bundle: .module)
        case .requiresApproval: String(localized: "Allow Prism in System Settings → General → Login Items to finish enabling automatic startup.", bundle: .module)
        case .notFound: String(localized: "macOS could not find Prism's login item. Try enabling it again.", bundle: .module)
        }
    }
}

@MainActor
enum LoginItem {
    static let releasePath = "/Applications/Prism.app"
    static let releaseBundleIdentifier = "dev.prism.desktop"

    /// Only the signed release app in /Applications registers, so development builds never add login items.
    static func isInstalledApp(bundle: Bundle = .main) -> Bool {
        bundle.bundleIdentifier == releaseBundleIdentifier && bundle.bundleURL.standardizedFileURL.path == releasePath
    }

    static func status(service: any LoginItemService = SMAppService.mainApp, installed: Bool = isInstalledApp()) -> LoginItemStatus {
        installed ? LoginItemStatus(service.status) : .unsupported
    }

    static func set(_ enabled: Bool, service: any LoginItemService) throws {
        if enabled {
            // Approval is a user action in System Settings, not repeated registration.
            guard service.status != .enabled, service.status != .requiresApproval else { return }
            do {
                try service.register()
            } catch {
                // macOS may report launch-denied after successfully registering.
                guard service.status == .requiresApproval else { throw error }
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
