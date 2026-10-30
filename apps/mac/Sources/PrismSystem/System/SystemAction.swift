import AppKit
import Carbon.HIToolbox

/// Fixed system actions, ported from `system_power.rs`. Only these exact command IDs run; tests substitute
/// both confirmation and execution and never send power events to the host.
enum SystemAction: String, CaseIterable, Sendable {
    case lockScreen = "system:lock-screen"
    case sleep = "system:sleep"
    case sleepDisplays = "system:sleep-displays"
    case restart = "system:restart"
    case shutDown = "system:shutdown"
    case logOut = "system:log-out"
    case emptyTrash = "system:empty-trash"
    case quitAllApps = "system:quit-all-apps"

    /// The five power actions the Tauri app routes through `run_system_action`.
    static let power: [SystemAction] = [.sleep, .sleepDisplays, .restart, .shutDown, .logOut]

    init?(commandID: String) {
        self.init(rawValue: commandID)
    }

    var commandID: String { rawValue }

    var needsConfirmation: Bool {
        switch self {
        case .restart, .shutDown, .logOut, .emptyTrash, .quitAllApps: true
        case .lockScreen, .sleep, .sleepDisplays: false
        }
    }

    var englishTitle: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleep: "Sleep"
        case .sleepDisplays: "Sleep Displays"
        case .restart: "Restart"
        case .shutDown: "Shut Down"
        case .logOut: "Log Out"
        case .emptyTrash: "Empty Trash"
        case .quitAllApps: "Quit All Apps"
        }
    }

    var title: String { SystemStrings.localized(englishTitle) }

    var subtitle: String {
        switch self {
        case .lockScreen: String(localized: "Lock this Mac session", bundle: .module)
        case .sleep: String(localized: "Put this Mac to sleep", bundle: .module)
        case .sleepDisplays: String(localized: "Turn off displays until the next input", bundle: .module)
        case .restart: String(localized: "Restart this Mac after confirmation", bundle: .module)
        case .shutDown: String(localized: "Shut down this Mac after confirmation", bundle: .module)
        case .logOut: String(localized: "Log out of this Mac after confirmation", bundle: .module)
        case .emptyTrash: String(localized: "Permanently erase the items in the Trash after confirmation", bundle: .module)
        case .quitAllApps: String(localized: "Quit every open app after confirmation", bundle: .module)
        }
    }

    /// The message shown before a session-ending or irreversible action.
    var confirmationMessage: String {
        switch self {
        case .emptyTrash: String(localized: "Items in the Trash will be erased permanently. You can't undo this action.", bundle: .module)
        case .quitAllApps: String(localized: "Every open app will quit. Apps with unsaved changes ask before closing.", bundle: .module)
        default: String(localized: "Open apps will close. Continue?", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .sleep: "moon.fill"
        case .sleepDisplays: "display"
        case .restart: "arrow.clockwise"
        case .shutDown: "power"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .emptyTrash: "trash"
        case .quitAllApps: "xmark.rectangle.portrait"
        }
    }

    var keywords: [String] {
        let specific: [String] = switch self {
        case .lockScreen: ["lock", "screen", "session", "security", "화면 잠금", "잠금"]
        case .sleep: ["power", "sleep", "suspend", "잠자기", "절전"]
        case .sleepDisplays: ["power", "sleep displays", "display", "monitor", "화면 끄기", "디스플레이 잠자기"]
        case .restart: ["power", "restart", "reboot", "재시동", "재부팅"]
        case .shutDown: ["power", "shutdown", "shut down", "power off", "시스템 종료", "전원 끄기"]
        case .logOut: ["power", "logout", "log out", "sign out", "로그아웃"]
        case .emptyTrash: ["trash", "bin", "empty", "delete", "휴지통", "비우기"]
        case .quitAllApps: ["quit", "close", "apps", "applications", "all", "모든 앱", "종료"]
        }
        return ["system"] + specific
    }

    /// AERegistry.h event IDs for normal session requests, never forced termination.
    var sessionEventID: AEEventID? {
        switch self {
        case .sleep: AEEventID(kAESleep)
        case .restart: AEEventID(kAERestart)
        case .shutDown: AEEventID(kAEShutDown)
        case .logOut: AEEventID(kAELogOut)
        default: nil
        }
    }

    /// Asks for confirmation when needed, then executes once. Returns false when the user cancelled.
    static func run(_ action: SystemAction, confirm: (SystemAction) async -> Bool,
                    execute: (SystemAction) async throws -> Void) async throws -> Bool {
        if action.needsConfirmation, !(await confirm(action)) { return false }
        try await execute(action)
        return true
    }
}

struct SystemActionError: Error, Equatable {
    var message: String
}

/// Runs system actions on this Mac.
@MainActor
enum SystemActionExecutor {
    static func execute(_ action: SystemAction) async throws {
        switch action {
        case .lockScreen: try lockScreen()
        case .sleepDisplays: try await sleepDisplays()
        case .sleep, .restart, .shutDown, .logOut: try sendSessionEvent(action.sessionEventID!)
        case .emptyTrash: try await emptyTrash()
        case .quitAllApps: quitAllApps()
        }
    }

    /// Sends a session Apple Event to the system process (loginwindow). Apps may still ask to save documents or
    /// cancel; success means the request was sent, not that the transition completed.
    private static func sendSessionEvent(_ eventID: AEEventID) throws {
        var process = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber, bytes: &process,
                                            length: MemoryLayout<ProcessSerialNumber>.size)
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: eventID,
                                                      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        do {
            try event.sendEvent(options: [.noReply, .canInteract], timeout: TimeInterval(kAEDefaultTimeout))
        } catch {
            throw SystemActionError(message: String(localized: "macOS declined the session request.", bundle: .module))
        }
    }

    private static func sleepDisplays() async throws {
        let status = await Task.detached { () -> Int32 in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else { throw SystemActionError(message: String(localized: "macOS declined Sleep Displays.", bundle: .module)) }
    }

    /// Control-Command-Q is the public macOS Lock Screen shortcut.
    private static func lockScreen() throws {
        guard CGPreflightPostEventAccess() else {
            throw SystemActionError(message: String(localized: "Allow Prism Accessibility access before using Lock Screen.", bundle: .module))
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: keyDown)
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Finder empties the Trash on every volume. The first run asks for Automation access to Finder.
    private static func emptyTrash() async throws {
        let failure = await Task.detached { () -> String? in
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"com.apple.finder\" to empty trash")?.executeAndReturnError(&error)
            return error.map { ($0[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "" }
        }.value
        if let failure {
            let message = failure == "-1743"
                ? String(localized: "Allow Prism to control Finder in System Settings > Privacy & Security > Automation.", bundle: .module)
                : String(localized: "Finder could not empty the Trash.", bundle: .module)
            throw SystemActionError(message: message)
        }
    }

    private static func quitAllApps() {
        for application in quittableApplications() { application.terminate() }
    }

    /// Regular apps other than Prism and Finder. Each quits normally, so unsaved documents still prompt.
    static func quittableApplications() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
                && $0.bundleIdentifier != "com.apple.finder" && !$0.isTerminated
        }
    }
}
