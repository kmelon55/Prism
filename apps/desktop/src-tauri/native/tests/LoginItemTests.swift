import Foundation
import ServiceManagement

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
@main struct LoginItemTests {
    static func main() throws {
        let service = FakeLoginItem()
        try setLoginItem(true, service: service)
        assert(service.status == .enabled && service.registrations == 1)
        try setLoginItem(true, service: service)
        assert(service.registrations == 1)
        try setLoginItem(false, service: service)
        try setLoginItem(false, service: service)
        assert(service.status == .notRegistered && service.removals == 1)
        service.approval = true
        try setLoginItem(true, service: service)
        assert(service.status == .requiresApproval)
        try setLoginItem(true, service: service)
        assert(service.registrations == 2)
        try setLoginItem(false, service: service)
        assert(service.removals == 2)
        service.approval = false; service.failure = true
        do { try setLoginItem(true, service: service); fatalError("Registration failure was hidden") }
        catch { assert(service.status == .notRegistered) }
        service.status = .enabled
        do { try setLoginItem(false, service: service); fatalError("Removal failure was hidden") }
        catch { assert(service.status == .enabled) }
        service.failure = false; service.status = .notFound
        try setLoginItem(true, service: service)
        assert(service.status == .enabled)
        // The executable is not an installed app and must never register itself.
        assert(prismLoginItemStatus() == -1)
        if let error = prismSetLoginItem(true) { free(error) }
        else { fatalError("Uninstalled executable registered itself") }
        print("Login item tests passed (enable, disable, approval, failures, installation guard).")
    }
}
