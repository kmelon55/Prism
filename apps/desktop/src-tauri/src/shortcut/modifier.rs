use std::sync::OnceLock;
use tauri::AppHandle;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

pub(super) const NAMES: [&str; 4] = [
    "DoubleControl",
    "DoubleOption",
    "DoubleShift",
    "DoubleCommand",
];
#[derive(Clone, Copy, Debug)]
pub(super) enum Binding {
    Combination(Shortcut),
    Double(u32),
}
impl Binding {
    pub fn id(self) -> u64 {
        match self {
            Self::Combination(key) => key.id() as u64,
            Self::Double(kind) => (1u64 << 32) | kind as u64,
        }
    }
    pub fn register(self, app: &AppHandle) -> Result<(), String> {
        match self {
            Self::Combination(key) => app
                .global_shortcut()
                .register(key)
                .map_err(|e| e.to_string()),
            Self::Double(kind) => register(kind),
        }
    }
    pub fn unregister(self, app: &AppHandle) -> Result<(), String> {
        match self {
            Self::Combination(key) => app
                .global_shortcut()
                .unregister(key)
                .map_err(|e| e.to_string()),
            Self::Double(kind) => {
                #[cfg(target_os = "macos")]
                unsafe {
                    prism_modifier_shortcut_unregister(kind);
                }
                #[cfg(not(target_os = "macos"))]
                let _ = kind;
                Ok(())
            }
        }
    }
}
static HANDLER: OnceLock<Box<dyn Fn(u64) + Send + Sync>> = OnceLock::new();
pub(super) fn install(handler: impl Fn(u64) + Send + Sync + 'static) {
    let _ = HANDLER.set(Box::new(handler));
}
#[cfg(target_os = "macos")]
extern "C" fn fired(kind: u32) {
    if let Some(handler) = HANDLER.get() {
        handler(Binding::Double(kind).id());
    }
}
#[cfg(target_os = "macos")]
extern "C" {
    fn prism_modifier_shortcut_register(kind: u32, callback: extern "C" fn(u32)) -> i32;
    fn prism_modifier_shortcut_unregister(kind: u32);
    fn prism_modifier_shortcut_capture(owner: *const std::ffi::c_char, active: bool);
}
fn register(kind: u32) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    match unsafe { prism_modifier_shortcut_register(kind, fired) } {
        0 => Ok(()),
        1 => Err("Modifier double-tap shortcuts require Accessibility access. Allow Prism in Permissions, then save the shortcut again.".into()),
        2 => Err("This modifier double-tap is already assigned to another Prism shortcut.".into()),
        _ => Err("Prism could not monitor modifier shortcuts.".into()),
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = kind;
        Err("Modifier double-tap shortcuts require macOS.".into())
    }
}

#[tauri::command]
pub fn set_shortcut_capture(
    window: tauri::WebviewWindow,
    owner: String,
    active: bool,
) -> Result<(), String> {
    if !matches!(owner.as_str(), "settings" | "dictation") {
        return Err("Unknown shortcut recorder.".into());
    }
    #[cfg(target_os = "macos")]
    {
        let owner = std::ffi::CString::new(format!("{}:{owner}", window.label()))
            .map_err(|e| e.to_string())?;
        unsafe {
            prism_modifier_shortcut_capture(owner.as_ptr(), active);
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (window, active);
    Ok(())
}
