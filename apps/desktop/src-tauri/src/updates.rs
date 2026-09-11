//! One process owns update checks and installation for every Prism window.
use serde::Serialize;
use std::{sync::Mutex, time::Duration};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_updater::{Update, UpdaterExt};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    current_version: String,
    phase: String,
    version: Option<String>,
    error: Option<String>,
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
                phase: if cfg!(debug_assertions) { "development" } else { "idle" }.into(),
                version: None,
                error: None,
            }),
            pending: Mutex::new(None),
            operation: tokio::sync::Mutex::new(()),
        }
    }
}
fn publish(app: &AppHandle, state: &Updates, phase: &str, version: Option<String>, error: Option<String>) -> UpdateStatus {
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
pub async fn check_for_updates(app: AppHandle, state: State<'_, Updates>) -> Result<UpdateStatus, String> {
    if cfg!(debug_assertions) { return Ok(get_update_status(state)); }
    let _guard = state.operation.try_lock().map_err(|_| "An update operation is already running.")?;
    if state.status.lock().unwrap().phase == "installed" { return Ok(get_update_status(state.clone())); }
    publish(&app, &state, "checking", None, None);
    let result = async {
        app.updater_builder().timeout(Duration::from_secs(30)).build()?.check().await
    }.await;
    match result {
        Ok(update) => {
            let version = update.as_ref().map(|value| value.version.clone());
            let phase = if update.is_some() { "available" } else { "current" };
            *state.pending.lock().unwrap() = update;
            Ok(publish(&app, &state, phase, version, None))
        }
        Err(error) => {
            *state.pending.lock().unwrap() = None;
            Ok(publish(&app, &state, "error", None, Some(error.to_string())))
        }
    }
}
#[tauri::command]
pub async fn install_update(app: AppHandle, state: State<'_, Updates>) -> Result<UpdateStatus, String> {
    if cfg!(debug_assertions) { return Err("Development builds cannot install updates.".into()); }
    let _guard = state.operation.try_lock().map_err(|_| "An update operation is already running.")?;
    let update = state.pending.lock().unwrap().clone().ok_or("Check for an update first.")?;
    let version = Some(update.version.clone());
    publish(&app, &state, "installing", version.clone(), None);
    let result: Result<(), String> = async {
        // download() verifies the updater signature before returning the bytes.
        let bytes = update.download(|_, _| {}, || {}).await.map_err(|error| error.to_string())?;
        tauri::async_runtime::spawn_blocking(move || {
            #[cfg(target_os = "macos")]
            {
                let executable = std::env::current_exe().map_err(|error| error.to_string())?;
                let installed = executable.ancestors()
                    .find(|path| path.extension().is_some_and(|extension| extension == "app"))
                    .ok_or("Install Prism in Applications before updating.")?;
                crate::update_signature::verify(&bytes, installed)?;
            }
            update.install(&bytes).map_err(|error| error.to_string())
        }).await.map_err(|error| error.to_string())?
    }.await;
    match result {
        Ok(()) => {
            *state.pending.lock().unwrap() = None;
            Ok(publish(&app, &state, "installed", version, None))
        }
        Err(error) => Ok(publish(&app, &state, "error", version, Some(error.to_string()))),
    }
}
#[tauri::command]
pub fn restart_after_update(app: AppHandle, state: State<'_, Updates>) -> Result<(), String> {
    if state.status.lock().unwrap().phase != "installed" { return Err("No installed update is ready.".into()); }
    app.request_restart();
    Ok(())
}
pub fn start(app: AppHandle) {
    if cfg!(debug_assertions) { return; }
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(20)).await;
        loop {
            let _ = check_for_updates(app.clone(), app.state::<Updates>()).await;
            tokio::time::sleep(Duration::from_secs(6 * 60 * 60)).await;
        }
    });
}
