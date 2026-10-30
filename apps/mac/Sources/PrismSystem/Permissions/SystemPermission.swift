import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import PrismKit

/// macOS privacy permissions Prism features rely on.
enum SystemPermission: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case screenRecording
    case microphone
    case automation

    var id: String { rawValue }

    enum State: Equatable, Sendable {
        case granted
        /// Not granted yet; Prism can show the system prompt.
        case notDetermined
        /// Refused or not yet enabled; only System Settings can change it.
        case denied
        case unknown
    }

    var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility", bundle: .module)
        case .screenRecording: String(localized: "Screen Recording", bundle: .module)
        case .microphone: String(localized: "Microphone", bundle: .module)
        case .automation: String(localized: "Automation", bundle: .module)
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: String(localized: "Used to arrange other apps’ windows and insert dictated text.", bundle: .module)
        case .screenRecording: String(localized: "Used to capture a screen region for Capture and Ask AI.", bundle: .module)
        case .microphone: String(localized: "Used only while dictation is recording.", bundle: .module)
        case .automation: String(localized: "Used to empty the Trash through Finder and run scripts you choose.", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic.fill"
        case .automation: "gearshape.2.fill"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Reads the current state without prompting. Automation is checked against Finder, which Empty Trash uses.
    func currentState() async -> State {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            case .denied, .restricted: .denied
            @unknown default: .unknown
            }
        case .automation:
            return await Task.detached { Self.automationState(prompt: false) }.value
        }
    }

    /// Whether Prism can still show a system prompt. Otherwise only System Settings can change the state.
    func canRequest(in state: State) -> Bool {
        switch self {
        case .accessibility, .screenRecording: state != .granted
        case .microphone: state == .notDetermined && Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        case .automation: state == .notDetermined
        }
    }

    /// Shows the system prompt. Accessibility and Screen Recording prompts lead to System Settings.
    @MainActor
    func request() async {
        switch self {
        case .accessibility:
            Permissions.requestAccessibility()
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .microphone:
            // Requesting without a usage description terminates the process, as in unbundled development builds.
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { return openSettings() }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .automation:
            _ = await Task.detached { Self.automationState(prompt: true) }.value
        }
    }

    @MainActor
    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    private nonisolated static func automationState(prompt: Bool) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
        return switch status {
        case noErr: .granted
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
        case OSStatus(errAEEventNotPermitted): .denied
        default: .unknown
        }
    }
}
