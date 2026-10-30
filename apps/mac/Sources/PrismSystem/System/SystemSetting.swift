import Foundation

/// System Settings destinations, ported from `system_commands.rs`. Only these fixed URLs open.
enum SystemSetting: String, CaseIterable, Sendable {
    case appearance = "system:settings:appearance"
    case display = "system:settings:display"
    case sound = "system:settings:sound"
    case bluetooth = "system:settings:bluetooth"
    case network = "system:settings:network"
    case privacySecurity = "system:settings:privacy-security"
    case notifications = "system:settings:notifications"
    case keyboard = "system:settings:keyboard"
    case mouse = "system:settings:mouse"
    case trackpad = "system:settings:trackpad"
    case powerBattery = "system:settings:power-battery"
    case dateTime = "system:settings:date-time"
    case softwareUpdate = "system:settings:software-update"

    var commandID: String { rawValue }

    var url: URL {
        let pane = switch self {
        case .appearance: "com.apple.Appearance-Settings.extension"
        case .display: "com.apple.Displays-Settings.extension"
        case .sound: "com.apple.Sound-Settings.extension"
        case .bluetooth: "com.apple.BluetoothSettings"
        case .network: "com.apple.Network-Settings.extension"
        case .privacySecurity: "com.apple.settings.PrivacySecurity.extension"
        case .notifications: "com.apple.Notifications-Settings.extension"
        case .keyboard: "com.apple.Keyboard-Settings.extension"
        case .mouse: "com.apple.Mouse-Settings.extension"
        case .trackpad: "com.apple.Trackpad-Settings.extension"
        case .powerBattery: "com.apple.Battery-Settings.extension"
        case .dateTime: "com.apple.Date-Time-Settings.extension"
        case .softwareUpdate: "com.apple.Software-Update-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    var englishTitle: String {
        switch self {
        case .appearance: "Appearance"
        case .display: "Displays"
        case .sound: "Sound"
        case .bluetooth: "Bluetooth"
        case .network: "Network"
        case .privacySecurity: "Privacy & Security"
        case .notifications: "Notifications"
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .trackpad: "Trackpad"
        case .powerBattery: "Battery"
        case .dateTime: "Date & Time"
        case .softwareUpdate: "Software Update"
        }
    }

    var title: String { SystemStrings.localized(englishTitle) }
    var subtitle: String { SystemStrings.localized("Open macOS \(englishTitle) settings") }

    var keywords: [String] {
        let specific: [String] = switch self {
        case .appearance: ["theme", "dark", "light", "accent"]
        case .display: ["monitor", "resolution", "brightness", "night shift"]
        case .sound: ["audio", "volume", "speaker", "microphone"]
        case .bluetooth: ["wireless", "devices", "pair", "airpods"]
        case .network: ["wifi", "wi-fi", "ethernet", "vpn", "internet"]
        case .privacySecurity: ["permissions", "security", "location", "camera", "microphone"]
        case .notifications: ["alerts", "focus", "banners", "sounds"]
        case .keyboard: ["input", "text", "shortcuts", "language"]
        case .mouse: ["pointer", "click", "scroll", "tracking"]
        case .trackpad: ["gesture", "click", "scroll", "tracking"]
        case .powerBattery: ["power", "energy", "charging", "low power"]
        case .dateTime: ["clock", "timezone", "calendar", "automatic"]
        case .softwareUpdate: ["update", "upgrade", "version", "macos"]
        }
        return ["system", "settings", "preferences"] + specific
    }

    /// The settings extension bundle, whose Finder icon matches System Settings' own sidebar icon.
    var iconPath: String? {
        let candidates: [String] = switch self {
        case .appearance: ["/System/Library/ExtensionKit/Extensions/Appearance.appex"]
        case .display: ["/System/Library/ExtensionKit/Extensions/DisplaysExt.appex"]
        case .sound: ["/System/Library/ExtensionKit/Extensions/Sound.appex"]
        case .bluetooth: ["/System/Library/ExtensionKit/Extensions/Bluetooth.appex"]
        case .network: ["/System/Library/ExtensionKit/Extensions/Network.appex"]
        case .privacySecurity: ["/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"]
        case .notifications: ["/System/Library/ExtensionKit/Extensions/NotificationsSettings.appex"]
        case .keyboard: ["/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex"]
        case .mouse: ["/System/Library/ExtensionKit/Extensions/MouseExtension.appex"]
        case .trackpad: ["/System/Library/ExtensionKit/Extensions/TrackpadExtension.appex"]
        case .powerBattery: ["/System/Library/ExtensionKit/Extensions/PowerPreferences.appex"]
        case .dateTime: ["/System/Library/ExtensionKit/Extensions/DateAndTime Extension.appex"]
        case .softwareUpdate: ["/System/Library/ExtensionKit/Extensions/SoftwareUpdateSettingsExtension.appex"]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    var systemImage: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .display: "display"
        case .sound: "speaker.wave.2.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .network: "network"
        case .privacySecurity: "hand.raised.fill"
        case .notifications: "bell.badge.fill"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .powerBattery: "battery.100"
        case .dateTime: "clock"
        case .softwareUpdate: "gear.badge"
        }
    }
}

extension SystemAction {
    /// Lock Screen uses the System Settings Lock Screen icon when available.
    var iconPath: String? {
        guard self == .lockScreen else { return nil }
        let path = "/System/Library/ExtensionKit/Extensions/LockScreen.appex"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
