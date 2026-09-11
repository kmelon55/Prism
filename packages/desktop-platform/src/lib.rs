//! OS mechanisms only. Command policy, confirmation, layout calculation and UI live in Prism.
use serde::Serialize;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
pub use windows::*;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub mod credentials;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerAction {
    Sleep,
    SleepDisplays,
    Restart,
    ShutDown,
    LogOut,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TargetWindow {
    pub id: usize,
    pub pid: u32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Bounds {
    pub fn valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .into_iter()
            .all(f64::is_finite)
            && self.width >= 1.0
            && self.height >= 1.0
            && self.x.abs() <= i32::MAX as f64
            && self.y.abs() <= i32::MAX as f64
            && self.width <= i32::MAX as f64
            && self.height <= i32::MAX as f64
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub window_management: bool,
    pub paste: bool,
    pub sleep_displays: bool,
    pub log_out: bool,
    pub reason: Option<String>,
}

#[cfg(any(target_os = "linux", test))]
fn linux_capabilities(wayland: bool, display: bool, desktop: &str) -> Capabilities {
    let x11 = !wayland && display;
    let desktop = desktop.to_ascii_lowercase();
    Capabilities {
        window_management: x11, paste: x11, sleep_displays: x11,
        log_out: desktop.contains("gnome") || desktop.contains("kde"),
        reason: (!x11).then(|| "This desktop session does not expose control of other applications. Use Copy or an X11 session.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn xwayland_does_not_advertise_control_of_native_wayland_windows() {
        let caps = linux_capabilities(true, true, "ubuntu:GNOME");
        assert!(!caps.window_management && !caps.paste && !caps.sleep_displays);
        assert!(caps.log_out);
        assert!(caps.reason.is_some());
    }
    #[test]
    fn x11_support_and_session_logout_are_independent() {
        let caps = linux_capabilities(false, true, "XFCE");
        assert!(caps.window_management && caps.paste && caps.sleep_displays);
        assert!(!caps.log_out);
        assert!(caps.reason.is_none());
        assert!(!linux_capabilities(false, false, "").window_management);
        assert!(linux_capabilities(true, false, "KDE").log_out);
    }
    #[test]
    fn rejects_invalid_native_coordinates() {
        let valid = Bounds {
            x: -1920.0,
            y: 0.0,
            width: 960.0,
            height: 1080.0,
        };
        assert!(valid.valid());
        for width in [0.0, -1.0, f64::NAN, f64::INFINITY, i32::MAX as f64 + 1.0] {
            assert!(!Bounds { width, ..valid }.valid());
        }
    }
}
