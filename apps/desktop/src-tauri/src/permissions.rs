use serde::Serialize;
use std::sync::{Mutex, OnceLock};
use tauri::{Emitter, Manager};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionRuntime {
    executable_path: String,
    permission_target: String,
    bundled: bool,
    ad_hoc: bool,
    identifier: Option<String>,
    code_hash: Option<String>,
    pid: u32,
}

fn runtime_from(executable: std::path::PathBuf, signature: &str) -> PermissionRuntime {
    let bundle = executable
        .ancestors()
        .find(|path| path.extension().is_some_and(|ext| ext == "app"));
    let field = |name: &str| {
        signature
            .lines()
            .find_map(|line| line.strip_prefix(name))
            .map(str::to_owned)
    };
    PermissionRuntime {
        permission_target: bundle.unwrap_or(&executable).to_string_lossy().into_owned(),
        bundled: bundle.is_some(),
        executable_path: executable.to_string_lossy().into_owned(),
        ad_hoc: signature.contains("Signature=adhoc") || signature.contains("adhoc,"),
        identifier: field("Identifier="),
        code_hash: field("CDHash="),
        pid: std::process::id(),
    }
}
#[tauri::command]
pub async fn get_permission_runtime() -> Result<PermissionRuntime, String> {
    tauri::async_runtime::spawn_blocking(|| {
        static RUNTIME: OnceLock<PermissionRuntime> = OnceLock::new();
        if let Some(runtime) = RUNTIME.get() {
            return Ok(runtime.clone());
        }
        let executable = std::env::current_exe().map_err(|e| e.to_string())?;
        #[cfg(target_os = "macos")]
        let signature = std::process::Command::new("/usr/bin/codesign")
            .args(["-dv", "--verbose=4"])
            .arg(&executable)
            .output()
            .map(|output| String::from_utf8_lossy(&output.stderr).into_owned())
            .unwrap_or_default();
        #[cfg(not(target_os = "macos"))]
        let signature = String::new();
        let runtime = runtime_from(executable, &signature);
        let _ = RUNTIME.set(runtime.clone());
        Ok(runtime)
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn reveal_permission_target() -> Result<(), String> {
    let runtime = get_permission_runtime().await?;
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("/usr/bin/open")
            .arg("-R")
            .arg(runtime.permission_target)
            .spawn()
            .map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = runtime;
        Err("Permission targets are only used on macOS.".into())
    }
}

// Called from a worker, never while the AppKit main thread is waiting for it.
pub fn refresh(app: &tauri::AppHandle) -> crate::window_management::AccessibilityPermissionStatus {
    let status = crate::window_management::get_accessibility_permission_status();
    static LAST: Mutex<Option<bool>> = Mutex::new(None);
    let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
    if *last != Some(status.granted) {
        *last = Some(status.granted);
        if let Some(manager) = app.try_state::<crate::shortcut::GlobalShortcutManager>() {
            manager.refresh_modifier_permissions(app, status.granted);
        }
        let _ = app.emit("prism:permissions-changed", &status);
    }
    status
}
#[tauri::command]
pub async fn refresh_accessibility_permission(
    app: tauri::AppHandle,
) -> Result<crate::window_management::AccessibilityPermissionStatus, String> {
    tauri::async_runtime::spawn_blocking(move || refresh(&app))
        .await
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn distinguishes_bare_dev_binary_from_app_permission_target() {
        let signature = "Identifier=prism-dev\nSignature=adhoc\nCDHash=fixture-hash\n";
        let dev = runtime_from("/project/target/debug/prism-desktop".into(), signature);
        assert!(!dev.bundled && dev.ad_hoc);
        assert_eq!(dev.permission_target, dev.executable_path);
        assert_eq!(dev.code_hash.as_deref(), Some("fixture-hash"));
        let app = runtime_from(
            "/Applications/Prism.app/Contents/MacOS/prism-desktop".into(),
            "Identifier=dev.prism.desktop\nAuthority=Apple Development\n",
        );
        assert!(app.bundled && !app.ad_hoc);
        assert_eq!(app.permission_target, "/Applications/Prism.app");
    }
}
