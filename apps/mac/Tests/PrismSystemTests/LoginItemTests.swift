import Foundation
import ServiceManagement
import Testing
@testable import PrismSystem

/// Ported from `native/tests/LoginItemTests.swift` and `login_item.rs`. Never touches the host's login items.
@MainActor
final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var approval = false
    var failure = false

    func register() throws {
        registrations += 1
        if approval { status = .requiresApproval }
        if failure || approval { throw NSError(domain: "test", code: 1) }
        status = .enabled
    }

    func unregister() throws {
        removals += 1
        if failure { throw NSError(domain: "test", code: 2) }
        status = .notRegistered
    }
}

@MainActor
struct LoginItemTests {
    @Test func enableDisableApprovalAndFailures() throws {
        let service = FakeLoginItem()
        try LoginItem.set(true, service: service)
        #expect(service.status == .enabled && service.registrations == 1)
        try LoginItem.set(true, service: service)
        #expect(service.registrations == 1)
        try LoginItem.set(false, service: service)
        try LoginItem.set(false, service: service)
        #expect(service.status == .notRegistered && service.removals == 1)

        service.approval = true
        try LoginItem.set(true, service: service)
        #expect(service.status == .requiresApproval)
        try LoginItem.set(true, service: service)
        #expect(service.registrations == 2)
        try LoginItem.set(false, service: service)
        #expect(service.removals == 2)

        service.approval = false
        service.failure = true
        #expect(throws: (any Error).self) { try LoginItem.set(true, service: service) }
        #expect(service.status == .notRegistered)
        service.status = .enabled
        #expect(throws: (any Error).self) { try LoginItem.set(false, service: service) }
        #expect(service.status == .enabled)

        service.failure = false
        service.status = .notFound
        try LoginItem.set(true, service: service)
        #expect(service.status == .enabled)
    }

    @Test func mapsAllServiceStatesWithoutClaimingUnknownStatesAreEnabled() {
        #expect(LoginItemStatus(.notRegistered) == .notRegistered)
        #expect(LoginItemStatus(.enabled) == .enabled)
        #expect(LoginItemStatus(.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(.notFound) == .notFound)
    }

    @Test func uninstalledExecutablesNeverRegister() {
        #expect(!LoginItem.isInstalledApp())
        let service = FakeLoginItem()
        let model = LaunchAtLoginModel(service: service, installed: false)
        model.refresh()
        #expect(model.status == .unsupported)
        model.set(true)
        #expect(service.registrations == 0)
    }

    @Test func toggleModelReflectsTheService() {
        let service = FakeLoginItem()
        let model = LaunchAtLoginModel(service: service, installed: true)
        model.refresh()
        #expect(model.status == .notRegistered && model.status?.isOn == false)
        model.set(true)
        #expect(model.status == .enabled && model.error == nil)
        service.failure = true
        model.set(false)
        #expect(model.status == .enabled)
        #expect(model.error != nil)
        service.failure = false
        service.status = .notRegistered
        service.approval = true
        model.set(true)
        #expect(model.status == .requiresApproval && model.status?.isOn == true && model.error == nil)
    }
}

struct PermissionRuntimeTests {
    @Test func distinguishesBareDevBinaryFromAppPermissionTarget() {
        let dev = PermissionRuntime(executable: URL(filePath: "/project/.build/debug/Prism"),
                                    signature: "Identifier=prism-dev\nSignature=adhoc\nCDHash=fixture-hash\n")
        #expect(!dev.bundled && dev.adHoc)
        #expect(dev.permissionTarget == dev.executablePath)
        #expect(dev.codeHash == "fixture-hash")
        #expect(dev.identifier == "prism-dev")

        let app = PermissionRuntime(executable: URL(filePath: "/Applications/Prism.app/Contents/MacOS/Prism"),
                                    signature: "Identifier=dev.prism.desktop\nAuthority=Apple Development\n")
        #expect(app.bundled && !app.adHoc)
        #expect(app.permissionTarget == "/Applications/Prism.app")
    }

    @Test func permissionSettingsLinksPointAtPrivacyPanes() {
        for permission in SystemPermission.allCases {
            #expect(permission.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"))
        }
    }
}
