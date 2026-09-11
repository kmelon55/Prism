//! One process owns update checks and installation for every Prism window.
use serde::{Deserialize, Serialize};
use std::{path::Path, sync::Mutex, time::Duration};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_updater::{Update, UpdaterExt};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    current_version: String,
    phase: String,
    version: Option<String>,
    error: Option<String>,
    automatic_install: bool,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct UpdatePreferences {
    #[serde(default)]
    automatic_install: bool,
}
const PREFERENCES_FILE: &str = "updates-v1.json";
fn read_preferences(path: &Path) -> UpdatePreferences {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}
fn save_preferences(path: &Path, preferences: &UpdatePreferences) -> Result<(), String> {
    let parent = path.parent().ok_or("Could not find update settings.")?;
    std::fs::create_dir_all(parent).map_err(|_| "Could not save update settings.")?;
    let temporary = path.with_extension("tmp");
    std::fs::write(
        &temporary,
        serde_json::to_vec(preferences).map_err(|_| "Could not save update settings.")?,
    )
    .and_then(|_| std::fs::rename(&temporary, path))
    .map_err(|_| "Could not save update settings.".into())
}

pub struct Updates {
    status: Mutex<UpdateStatus>,
    pending: Mutex<Option<Update>>,
    operation: tokio::sync::Mutex<()>,
}
impl Default for Updates {
    fn default() -> Self {
        Self {
            status: Mutex::new(UpdateStatus {
                current_version: env!("CARGO_PKG_VERSION").into(),
                phase: if cfg!(debug_assertions) {
                    "development"
                } else {
                    "idle"
                }
                .into(),
                version: None,
                error: None,
                automatic_install: false,
            }),
            pending: Mutex::new(None),
            operation: tokio::sync::Mutex::new(()),
        }
    }
}
fn publish(
    app: &AppHandle,
    state: &Updates,
    phase: &str,
    version: Option<String>,
    error: Option<String>,
) -> UpdateStatus {
    let mut status = state.status.lock().unwrap();
    status.phase = phase.into();
    status.version = version;
    status.error = error;
    let _ = app.emit("prism:update-status", &*status);
    status.clone()
}
#[tauri::command]
pub fn get_update_status(state: State<'_, Updates>) -> UpdateStatus {
    state.status.lock().unwrap().clone()
}
#[tauri::command]
pub async fn set_automatic_updates(
    app: AppHandle,
    state: State<'_, Updates>,
    enabled: bool,
) -> Result<UpdateStatus, String> {
    {
        let _guard = state
            .operation
            .try_lock()
            .map_err(|_| "An update operation is already running.")?;
        let path = app
            .path()
            .app_data_dir()
            .map_err(|_| "Could not find update settings.")?
            .join(PREFERENCES_FILE);
        save_preferences(
            &path,
            &UpdatePreferences {
                automatic_install: enabled,
            },
        )?;
        let mut status = state.status.lock().unwrap();
        status.automatic_install = enabled;
        let _ = app.emit("prism:update-status", &*status);
    }
    if enabled && !cfg!(debug_assertions) {
        start_automatic_install(app.clone());
    }
    Ok(get_update_status(state))
}
#[tauri::command]
pub async fn check_for_updates(
    app: AppHandle,
    state: State<'_, Updates>,
) -> Result<UpdateStatus, String> {
    if cfg!(debug_assertions) {
        return Ok(get_update_status(state));
    }
    let _guard = state
        .operation
        .try_lock()
        .map_err(|_| "An update operation is already running.")?;
    if state.status.lock().unwrap().phase == "installed" {
        return Ok(get_update_status(state.clone()));
    }
    let previous_version = state.status.lock().unwrap().version.clone();
    publish(&app, &state, "checking", previous_version.clone(), None);
    let result = async {
        app.updater_builder()
            .timeout(Duration::from_secs(30))
            .build()?
            .check()
            .await
    }
    .await;
    let status = match result {
        Ok(update) => {
            let version = update.as_ref().map(|value| value.version.clone());
            let phase = if update.is_some() {
                "available"
            } else {
                "current"
            };
            *state.pending.lock().unwrap() = update;
            publish(&app, &state, phase, version, None)
        }
        Err(error) => {
            // A transient check failure must not discard an already-discovered update.
            let phase = if state.pending.lock().unwrap().is_some() {
                "available"
            } else {
                "error"
            };
            publish(
                &app,
                &state,
                phase,
                previous_version,
                Some(error.to_string()),
            )
        }
    };
    drop(_guard);
    if should_auto_install(&status) {
        start_automatic_install(app);
    }
    Ok(status)
}
#[tauri::command]
pub async fn install_update(
    app: AppHandle,
    state: State<'_, Updates>,
) -> Result<UpdateStatus, String> {
    perform_install(app, state, false).await
}
fn should_auto_install(status: &UpdateStatus) -> bool {
    status.automatic_install && status.phase == "available"
}
fn start_automatic_install(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let _ = perform_install(app.clone(), app.state::<Updates>(), true).await;
    });
}
async fn perform_install(
    app: AppHandle,
    state: State<'_, Updates>,
    automatic: bool,
) -> Result<UpdateStatus, String> {
    if cfg!(debug_assertions) {
        return Err("Development builds cannot install updates.".into());
    }
    let _guard = state
        .operation
        .try_lock()
        .map_err(|_| "An update operation is already running.")?;
    if automatic && !should_auto_install(&state.status.lock().unwrap()) {
        return Ok(get_update_status(state.clone()));
    }
    let update = state
        .pending
        .lock()
        .unwrap()
        .clone()
        .ok_or("Check for an update first.")?;
    let version = Some(update.version.clone());
    publish(&app, &state, "installing", version.clone(), None);
    let result: Result<(), String> = async {
        // download() verifies the updater signature before returning the bytes.
        let bytes = update
            .download(|_, _| {}, || {})
            .await
            .map_err(|error| error.to_string())?;
        tauri::async_runtime::spawn_blocking(move || {
            #[cfg(target_os = "macos")]
            {
                let executable = std::env::current_exe().map_err(|error| error.to_string())?;
                let installed = executable
                    .ancestors()
                    .find(|path| path.extension().is_some_and(|extension| extension == "app"))
                    .ok_or("Install Prism in Applications before updating.")?;
                crate::update_signature::verify(&bytes, installed)?;
            }
            update.install(&bytes).map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }
    .await;
    match result {
        Ok(()) => {
            *state.pending.lock().unwrap() = None;
            Ok(publish(&app, &state, "installed", version, None))
        }
        Err(error) => Ok(publish(
            &app,
            &state,
            "error",
            version,
            Some(error.to_string()),
        )),
    }
}
#[tauri::command]
pub fn restart_after_update(app: AppHandle, state: State<'_, Updates>) -> Result<(), String> {
    if state.status.lock().unwrap().phase != "installed" {
        return Err("No installed update is ready.".into());
    }
    app.request_restart();
    Ok(())
}
pub fn start(app: AppHandle) {
    if let Ok(directory) = app.path().app_data_dir() {
        app.state::<Updates>()
            .status
            .lock()
            .unwrap()
            .automatic_install =
            read_preferences(&directory.join(PREFERENCES_FILE)).automatic_install;
    }
    if cfg!(debug_assertions) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(20)).await;
        loop {
            let _ = check_for_updates(app.clone(), app.state::<Updates>()).await;
            tokio::time::sleep(Duration::from_secs(6 * 60 * 60)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn automatic_install_requires_persisted_opt_in_and_an_available_update() {
        let mut status = Updates::default().status.into_inner().unwrap();
        status.phase = "available".into();
        assert!(!should_auto_install(&status));
        status.automatic_install = true;
        assert!(should_auto_install(&status));
        for phase in [
            "idle",
            "development",
            "checking",
            "current",
            "installing",
            "installed",
            "error",
        ] {
            status.phase = phase.into();
            assert!(
                !should_auto_install(&status),
                "{phase} must not trigger an installation"
            );
        }
    }
    #[test]
    fn preferences_survive_restart_and_invalid_preferences_never_opt_in() {
        let directory = std::env::temp_dir().join(format!(
            "prism-update-preferences-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = directory.join(PREFERENCES_FILE);
        assert!(!read_preferences(&path).automatic_install);
        save_preferences(
            &path,
            &UpdatePreferences {
                automatic_install: true,
            },
        )
        .unwrap();
        assert!(read_preferences(&path).automatic_install);
        save_preferences(
            &path,
            &UpdatePreferences {
                automatic_install: false,
            },
        )
        .unwrap();
        assert!(!read_preferences(&path).automatic_install);
        for invalid in ["{", "{}", r#"{"automaticInstall":"true"}"#] {
            std::fs::write(&path, invalid).unwrap();
            assert!(!read_preferences(&path).automatic_install);
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
