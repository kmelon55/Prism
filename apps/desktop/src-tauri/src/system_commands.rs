use serde::Serialize;
#[cfg(target_os = "linux")]
use std::io;
#[cfg(target_os = "macos")]
use std::path::PathBuf;
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::process::Command;

const APPEARANCE: &str = "system:settings:appearance";
const DISPLAY: &str = "system:settings:display";
const SOUND: &str = "system:settings:sound";
const BLUETOOTH: &str = "system:settings:bluetooth";
const NETWORK: &str = "system:settings:network";
const PRIVACY_SECURITY: &str = "system:settings:privacy-security";
const NOTIFICATIONS: &str = "system:settings:notifications";
const KEYBOARD: &str = "system:settings:keyboard";
const MOUSE: &str = "system:settings:mouse";
const TRACKPAD: &str = "system:settings:trackpad";
const POWER_BATTERY: &str = "system:settings:power-battery";
const DATE_TIME: &str = "system:settings:date-time";
const SOFTWARE_UPDATE: &str = "system:settings:software-update";
const LOCK_SCREEN: &str = "system:lock-screen";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SystemSetting {
    Appearance,
    Display,
    Sound,
    Bluetooth,
    Network,
    PrivacySecurity,
    Notifications,
    Keyboard,
    Mouse,
    Trackpad,
    PowerBattery,
    DateTime,
    SoftwareUpdate,
}

impl SystemSetting {
    fn parse(command_id: &str) -> Result<Self, SystemCommandError> {
        match command_id {
            APPEARANCE => Ok(Self::Appearance),
            DISPLAY => Ok(Self::Display),
            SOUND => Ok(Self::Sound),
            BLUETOOTH => Ok(Self::Bluetooth),
            NETWORK => Ok(Self::Network),
            PRIVACY_SECURITY => Ok(Self::PrivacySecurity),
            NOTIFICATIONS => Ok(Self::Notifications),
            KEYBOARD => Ok(Self::Keyboard),
            MOUSE => Ok(Self::Mouse),
            TRACKPAD => Ok(Self::Trackpad),
            POWER_BATTERY => Ok(Self::PowerBattery),
            DATE_TIME => Ok(Self::DateTime),
            SOFTWARE_UPDATE => Ok(Self::SoftwareUpdate),
            _ => Err(SystemCommandError::new(
                "unknownCommand",
                "Prism refused to open a system setting outside its native allowlist.",
            )),
        }
    }

    fn command_id(self) -> &'static str {
        match self {
            Self::Appearance => APPEARANCE,
            Self::Display => DISPLAY,
            Self::Sound => SOUND,
            Self::Bluetooth => BLUETOOTH,
            Self::Network => NETWORK,
            Self::PrivacySecurity => PRIVACY_SECURITY,
            Self::Notifications => NOTIFICATIONS,
            Self::Keyboard => KEYBOARD,
            Self::Mouse => MOUSE,
            Self::Trackpad => TRACKPAD,
            Self::PowerBattery => POWER_BATTERY,
            Self::DateTime => DATE_TIME,
            Self::SoftwareUpdate => SOFTWARE_UPDATE,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemCommandResult {
    command_id: String,
    platform: String,
    applied: bool,
    message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemCommandError {
    code: String,
    message: String,
}

impl SystemCommandError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    fn launch(action: &str, error: impl std::fmt::Display) -> Self {
        Self::new("launchFailed", format!("Prism could not {action}: {error}"))
    }

    #[cfg(target_os = "linux")]
    fn unsupported(message: impl Into<String>) -> Self {
        Self::new("unsupportedPlatform", message)
    }
}

#[tauri::command]
pub fn system_platform() -> &'static str {
    platform_name()
}

#[tauri::command]
pub fn desktop_capabilities() -> prism_desktop_platform::Capabilities {
    #[cfg(target_os = "macos")]
    return prism_desktop_platform::Capabilities {
        window_management: true, paste: true, sleep_displays: true, log_out: true, reason: None,
    };
    #[cfg(not(target_os = "macos"))]
    prism_desktop_platform::capabilities()
}

#[tauri::command]
pub fn open_system_setting(command_id: String) -> Result<SystemCommandResult, SystemCommandError> {
    let setting = SystemSetting::parse(&command_id)?;
    open_setting(setting)?;
    Ok(SystemCommandResult {
        command_id: setting.command_id().to_string(),
        platform: platform_name().to_string(),
        applied: true,
        message: "System settings opened.".to_string(),
    })
}

#[tauri::command]
pub fn lock_screen() -> Result<SystemCommandResult, SystemCommandError> {
    lock_current_session()?;
    Ok(SystemCommandResult {
        command_id: LOCK_SCREEN.to_string(),
        platform: platform_name().to_string(),
        applied: true,
        message: "Lock Screen requested.".to_string(),
    })
}

#[tauri::command]
pub async fn run_system_action(
    command_id: String,
    locale: Option<String>,
) -> Result<SystemCommandResult, SystemCommandError> {
    use crate::system_power::{self, SystemAction};
    use std::sync::atomic::{AtomicBool, Ordering};
    static BUSY: AtomicBool = AtomicBool::new(false);

    let action = SystemAction::parse(&command_id)
        .map_err(|message| SystemCommandError::new("unknownCommand", message))?;
    let capabilities = desktop_capabilities();
    if (action == SystemAction::SleepDisplays && !capabilities.sleep_displays)
        || (action == SystemAction::LogOut && !capabilities.log_out) {
        return Err(SystemCommandError::new(
            "unsupportedPlatform",
            "This action is unavailable in the current desktop session.",
        ));
    }
    if BUSY.swap(true, Ordering::AcqRel) {
        return Err(SystemCommandError::new(
            "actionBusy",
            "A system action is already pending.",
        ));
    }
    struct PendingAction;
    impl Drop for PendingAction {
        fn drop(&mut self) {
            BUSY.store(false, Ordering::Release);
        }
    }
    let pending = PendingAction;
    tauri::async_runtime::spawn_blocking(move || {
        let _pending = pending;
        let korean = locale.as_deref() == Some("ko");
        let applied = system_power::run_with(
            action,
            |action| {
                let title = action.title(korean);
                let result = rfd::MessageDialog::new()
                    .set_title(format!("Prism · {title}"))
                    .set_description(if korean {
                        "열려 있는 앱이 닫힙니다. 계속하시겠습니까?"
                    } else {
                        "Open apps will close. Continue?"
                    })
                    .set_level(rfd::MessageLevel::Warning)
                    .set_buttons(rfd::MessageButtons::OkCancelCustom(
                        title.into(),
                        if korean { "취소" } else { "Cancel" }.into(),
                    ))
                    .show();
                result == rfd::MessageDialogResult::Custom(title.into())
            },
            system_power::execute,
        )
        .map_err(|message| SystemCommandError::new("actionFailed", message))?;
        Ok(SystemCommandResult {
            command_id,
            platform: platform_name().into(),
            applied,
            // Cancellation is intentionally silent and leaves the palette open.
            message: String::new(),
        })
    })
    .await
    .map_err(|error| SystemCommandError::new("actionFailed", error.to_string()))?
}

fn platform_name() -> &'static str {
    #[cfg(target_os = "macos")]
    return "macos";

    #[cfg(target_os = "windows")]
    return "windows";

    #[cfg(target_os = "linux")]
    return "linux";

    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    "unsupported"
}

#[cfg(target_os = "macos")]
pub(crate) fn system_icon_target(command_id: &str) -> Result<Option<PathBuf>, String> {
    let candidates: &[&str] = match command_id {
        APPEARANCE => &[
            "/System/Library/ExtensionKit/Extensions/Appearance.appex",
            "/System/Library/PreferencePanes/Appearance.prefPane",
        ],
        DISPLAY => &[
            "/System/Library/ExtensionKit/Extensions/DisplaysExt.appex",
            "/System/Library/PreferencePanes/Displays.prefPane",
        ],
        SOUND => &[
            "/System/Library/ExtensionKit/Extensions/Sound.appex",
            "/System/Library/PreferencePanes/Sound.prefPane",
        ],
        BLUETOOTH => &[
            "/System/Library/ExtensionKit/Extensions/Bluetooth.appex",
            "/System/Library/PreferencePanes/Bluetooth.prefPane",
        ],
        NETWORK => &[
            "/System/Library/ExtensionKit/Extensions/Network.appex",
            "/System/Library/PreferencePanes/Network.prefPane",
        ],
        PRIVACY_SECURITY => &[
            "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex",
            "/System/Library/PreferencePanes/Security.prefPane",
        ],
        NOTIFICATIONS => &[
            "/System/Library/ExtensionKit/Extensions/NotificationsSettings.appex",
            "/System/Library/PreferencePanes/Notifications.prefPane",
        ],
        KEYBOARD => &[
            "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex",
            "/System/Library/PreferencePanes/Keyboard.prefPane",
        ],
        MOUSE => &[
            "/System/Library/ExtensionKit/Extensions/MouseExtension.appex",
            "/System/Library/PreferencePanes/Mouse.prefPane",
        ],
        TRACKPAD => &[
            "/System/Library/ExtensionKit/Extensions/TrackpadExtension.appex",
            "/System/Library/PreferencePanes/Trackpad.prefPane",
        ],
        POWER_BATTERY => &[
            "/System/Library/ExtensionKit/Extensions/PowerPreferences.appex",
            "/System/Library/PreferencePanes/Battery.prefPane",
            "/System/Library/PreferencePanes/EnergySaver.prefPane",
        ],
        DATE_TIME => &[
            "/System/Library/ExtensionKit/Extensions/DateAndTime Extension.appex",
            "/System/Library/PreferencePanes/DateAndTime.prefPane",
        ],
        SOFTWARE_UPDATE => &[
            "/System/Library/ExtensionKit/Extensions/SoftwareUpdateSettingsExtension.appex",
            "/System/Library/PreferencePanes/SoftwareUpdate.prefPane",
        ],
        LOCK_SCREEN => &["/System/Library/ExtensionKit/Extensions/LockScreen.appex"],
        _ => {
            return Err(
                "Prism refused to load an icon outside its system command allowlist.".to_string(),
            )
        }
    };

    Ok(candidates
        .iter()
        .map(PathBuf::from)
        .find(|candidate| candidate.is_dir()))
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn system_icon_target(command_id: &str) -> Result<Option<std::path::PathBuf>, String> {
    if command_id == LOCK_SCREEN || SystemSetting::parse(command_id).is_ok() {
        Ok(None)
    } else {
        Err("Prism refused to load an icon outside its system command allowlist.".to_string())
    }
}

#[cfg(target_os = "macos")]
fn macos_uri(setting: SystemSetting) -> &'static str {
    match setting {
        SystemSetting::Appearance => {
            "x-apple.systempreferences:com.apple.Appearance-Settings.extension"
        }
        SystemSetting::Display => "x-apple.systempreferences:com.apple.Displays-Settings.extension",
        SystemSetting::Sound => "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        SystemSetting::Bluetooth => "x-apple.systempreferences:com.apple.BluetoothSettings",
        SystemSetting::Network => "x-apple.systempreferences:com.apple.Network-Settings.extension",
        SystemSetting::PrivacySecurity => {
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        }
        SystemSetting::Notifications => {
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
        SystemSetting::Keyboard => {
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        }
        SystemSetting::Mouse => "x-apple.systempreferences:com.apple.Mouse-Settings.extension",
        SystemSetting::Trackpad => {
            "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        }
        SystemSetting::PowerBattery => {
            "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        }
        SystemSetting::DateTime => {
            "x-apple.systempreferences:com.apple.Date-Time-Settings.extension"
        }
        SystemSetting::SoftwareUpdate => {
            "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        }
    }
}

#[cfg(target_os = "windows")]
fn windows_uri(setting: SystemSetting) -> Result<&'static str, SystemCommandError> {
    match setting {
        SystemSetting::Appearance => Ok("ms-settings:personalization"),
        SystemSetting::Display => Ok("ms-settings:display"),
        SystemSetting::Sound => Ok("ms-settings:sound"),
        SystemSetting::Bluetooth => Ok("ms-settings:bluetooth"),
        SystemSetting::Network => Ok("ms-settings:network-status"),
        SystemSetting::PrivacySecurity => Ok("ms-settings:privacy"),
        SystemSetting::Notifications => Ok("ms-settings:notifications"),
        SystemSetting::Keyboard => Ok("ms-settings:typing"),
        SystemSetting::Mouse => Ok("ms-settings:mousetouchpad"),
        SystemSetting::Trackpad => Err(SystemCommandError::new(
            "unsupportedCommand",
            "Prism does not expose the hardware-dependent Windows trackpad page.",
        )),
        SystemSetting::PowerBattery => Ok("ms-settings:powersleep"),
        SystemSetting::DateTime => Ok("ms-settings:dateandtime"),
        SystemSetting::SoftwareUpdate => Ok("ms-settings:windowsupdate"),
    }
}

#[cfg(target_os = "linux")]
fn gnome_panel(setting: SystemSetting) -> &'static str {
    match setting {
        SystemSetting::Appearance => "background",
        SystemSetting::Display => "display",
        SystemSetting::Sound => "sound",
        SystemSetting::Bluetooth => "bluetooth",
        SystemSetting::Network => "network",
        SystemSetting::PrivacySecurity => "privacy",
        SystemSetting::Notifications => "notifications",
        SystemSetting::Keyboard => "keyboard",
        SystemSetting::Mouse | SystemSetting::Trackpad => "mouse",
        SystemSetting::PowerBattery => "power",
        SystemSetting::DateTime => "datetime",
        SystemSetting::SoftwareUpdate => "applications",
    }
}

#[cfg(target_os = "macos")]
fn open_setting(setting: SystemSetting) -> Result<(), SystemCommandError> {
    Command::new("/usr/bin/open")
        .arg(macos_uri(setting))
        .spawn()
        .map(|_| ())
        .map_err(|error| SystemCommandError::launch("open System Settings", error))
}

#[cfg(target_os = "windows")]
fn open_setting(setting: SystemSetting) -> Result<(), SystemCommandError> {
    use std::{ffi::c_void, iter, os::windows::ffi::OsStrExt, ptr};

    #[link(name = "shell32")]
    extern "system" {
        fn ShellExecuteW(
            window: *mut c_void,
            operation: *const u16,
            file: *const u16,
            parameters: *const u16,
            directory: *const u16,
            show_command: i32,
        ) -> *mut c_void;
    }

    let uri = windows_uri(setting)?;
    let uri = std::ffi::OsStr::new(uri)
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: Every pointer is either null or points to a NUL-terminated buffer that remains
    // alive for the duration of ShellExecuteW. The URI came from windows_uri's static allowlist.
    let result = unsafe {
        ShellExecuteW(
            ptr::null_mut(),
            ptr::null(),
            uri.as_ptr(),
            ptr::null(),
            ptr::null(),
            1,
        )
    } as isize;
    if result > 32 {
        Ok(())
    } else {
        Err(SystemCommandError::new(
            "launchFailed",
            format!("Windows could not open the allowed Settings URI (error {result})."),
        ))
    }
}

#[cfg(target_os = "linux")]
fn open_setting(setting: SystemSetting) -> Result<(), SystemCommandError> {
    const GNOME_SETTINGS: &str = "/usr/bin/gnome-control-center";
    const GENERIC_SETTINGS: [&str; 3] = [
        "/usr/bin/systemsettings6",
        "/usr/bin/systemsettings5",
        "/usr/bin/systemsettings",
    ];

    let desktop = std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_ascii_lowercase();
    if desktop.contains("gnome") && std::path::Path::new(GNOME_SETTINGS).is_file() {
        return Command::new(GNOME_SETTINGS)
            .arg(gnome_panel(setting))
            .spawn()
            .map(|_| ())
            .map_err(|error| SystemCommandError::launch("open system settings", error));
    }

    for executable in GENERIC_SETTINGS {
        match Command::new(executable).spawn() {
            Ok(_) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(SystemCommandError::launch("open system settings", error));
            }
        }
    }

    if std::path::Path::new(GNOME_SETTINGS).is_file() {
        return Command::new(GNOME_SETTINGS)
            .spawn()
            .map(|_| ())
            .map_err(|error| SystemCommandError::launch("open system settings", error));
    }

    Err(SystemCommandError::unsupported(
        "Prism could not find a supported Linux system settings application.",
    ))
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn open_setting(_setting: SystemSetting) -> Result<(), SystemCommandError> {
    Err(SystemCommandError::new(
        "unsupportedPlatform",
        "System settings are unavailable on this platform.",
    ))
}

#[cfg(target_os = "macos")]
fn lock_current_session() -> Result<(), SystemCommandError> {
    use std::{ffi::c_void, ptr};

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventCreateKeyboardEvent(
            source: *const c_void,
            virtual_key: u16,
            key_down: bool,
        ) -> *mut c_void;
        fn CGEventPost(tap: u32, event: *const c_void);
        fn CGPreflightPostEventAccess() -> bool;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFRelease(value: *const c_void);
    }

    // Control-Command-Q is the public macOS Lock Screen shortcut. Posting it through
    // Core Graphics keeps the action fixed in native code and avoids shell input.
    const HID_EVENT_TAP: u32 = 0;
    const Q_KEY: u16 = 12;
    const COMMAND_KEY: u16 = 55;
    const CONTROL_KEY: u16 = 59;
    const KEY_EVENTS: [(u16, bool); 6] = [
        (CONTROL_KEY, true),
        (COMMAND_KEY, true),
        (Q_KEY, true),
        (Q_KEY, false),
        (COMMAND_KEY, false),
        (CONTROL_KEY, false),
    ];

    // SAFETY: CGPreflightPostEventAccess has no parameters or memory preconditions.
    if !unsafe { CGPreflightPostEventAccess() } {
        Err(SystemCommandError::new(
            "permissionDenied",
            "Allow Prism Accessibility access before using Lock Screen.",
        ))
    } else {
        let mut events = Vec::with_capacity(KEY_EVENTS.len());
        for (key, down) in KEY_EVENTS {
            // SAFETY: A null event source requests the documented default source. No borrowed
            // pointers are retained, and each non-null event is released below.
            let event = unsafe { CGEventCreateKeyboardEvent(ptr::null(), key, down) };
            if event.is_null() {
                for pending in events {
                    // SAFETY: Each value was returned by CGEventCreateKeyboardEvent and has not
                    // previously been released.
                    unsafe { CFRelease(pending) };
                }
                return Err(SystemCommandError::new(
                    "actionFailed",
                    "macOS could not create the Lock Screen keyboard shortcut.",
                ));
            }
            events.push(event);
        }

        for event in events {
            // SAFETY: event is a live CGEventRef. CGEventPost does not retain it, so it is safe to
            // release immediately after posting.
            unsafe {
                CGEventPost(HID_EVENT_TAP, event);
                CFRelease(event);
            }
        }
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn lock_current_session() -> Result<(), SystemCommandError> {
    #[link(name = "user32")]
    extern "system" {
        fn LockWorkStation() -> i32;
    }

    // SAFETY: LockWorkStation takes no arguments and has no memory-safety preconditions.
    let locked = unsafe { LockWorkStation() };
    if locked != 0 {
        Ok(())
    } else {
        Err(SystemCommandError::new(
            "actionFailed",
            "Windows declined the Lock Screen request.",
        ))
    }
}

#[cfg(target_os = "linux")]
fn lock_current_session() -> Result<(), SystemCommandError> {
    const LOCK_COMMANDS: [(&str, &[&str]); 2] = [
        ("/usr/bin/xdg-screensaver", &["lock"]),
        ("/usr/bin/loginctl", &["lock-session"]),
    ];
    let mut failures = Vec::new();

    for (executable, arguments) in LOCK_COMMANDS {
        match Command::new(executable).args(arguments).status() {
            Ok(status) if status.success() => return Ok(()),
            Ok(status) => failures.push(format!("{executable} exited with {status}")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => failures.push(format!("{executable}: {error}")),
        }
    }

    let detail = if failures.is_empty() {
        "no supported lock command is installed".to_string()
    } else {
        failures.join("; ")
    };
    Err(SystemCommandError::new(
        "actionFailed",
        format!("Prism could not lock this Linux session: {detail}."),
    ))
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn lock_current_session() -> Result<(), SystemCommandError> {
    Err(SystemCommandError::new(
        "unsupportedPlatform",
        "Lock Screen is unavailable on this platform.",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setting_ids_round_trip_through_the_allowlist() {
        let ids = [
            APPEARANCE,
            DISPLAY,
            SOUND,
            BLUETOOTH,
            NETWORK,
            PRIVACY_SECURITY,
            NOTIFICATIONS,
            KEYBOARD,
            MOUSE,
            TRACKPAD,
            POWER_BATTERY,
            DATE_TIME,
            SOFTWARE_UPDATE,
        ];

        for id in ids {
            assert_eq!(SystemSetting::parse(id).unwrap().command_id(), id);
        }
    }

    #[test]
    fn executable_and_uri_payloads_are_not_accepted_as_command_ids() {
        for id in [
            "/usr/bin/open",
            "ms-settings:display",
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "system:shutdown",
        ] {
            let error = SystemSetting::parse(id).unwrap_err();
            assert_eq!(error.code, "unknownCommand");
        }
    }

    #[test]
    fn icon_targets_reject_unknown_command_ids() {
        assert!(system_icon_target("/tmp/not-a-system-icon").is_err());
        assert!(system_icon_target("system:shutdown").is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_icon_targets_resolve_installed_system_bundles() {
        for id in [
            APPEARANCE,
            DISPLAY,
            SOUND,
            BLUETOOTH,
            NETWORK,
            PRIVACY_SECURITY,
            NOTIFICATIONS,
            KEYBOARD,
            MOUSE,
            TRACKPAD,
            POWER_BATTERY,
            DATE_TIME,
            SOFTWARE_UPDATE,
            LOCK_SCREEN,
        ] {
            let target = system_icon_target(id)
                .expect("the command should be allowed")
                .expect("macOS should provide the matching settings bundle");
            assert!(target.starts_with("/System/Library"));
            assert!(target.is_dir());
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_settings_use_only_system_settings_deep_links() {
        for setting in [
            SystemSetting::Appearance,
            SystemSetting::Display,
            SystemSetting::Sound,
            SystemSetting::Bluetooth,
            SystemSetting::Network,
            SystemSetting::PrivacySecurity,
            SystemSetting::Notifications,
            SystemSetting::Keyboard,
            SystemSetting::Mouse,
            SystemSetting::Trackpad,
            SystemSetting::PowerBattery,
            SystemSetting::DateTime,
            SystemSetting::SoftwareUpdate,
        ] {
            assert!(macos_uri(setting).starts_with("x-apple.systempreferences:"));
        }
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_settings_use_only_official_ms_settings_uris() {
        for setting in [
            SystemSetting::Appearance,
            SystemSetting::Display,
            SystemSetting::Sound,
            SystemSetting::Bluetooth,
            SystemSetting::Network,
            SystemSetting::PrivacySecurity,
            SystemSetting::Notifications,
            SystemSetting::Keyboard,
            SystemSetting::Mouse,
            SystemSetting::PowerBattery,
            SystemSetting::DateTime,
            SystemSetting::SoftwareUpdate,
        ] {
            assert!(windows_uri(setting).unwrap().starts_with("ms-settings:"));
        }
    }
}
