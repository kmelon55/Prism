use crate::{app_catalog, application_index::ApplicationIndex};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use std::{
    path::Path,
    sync::{mpsc, Mutex},
    thread,
    time::Duration,
};
use tauri::{AppHandle, Emitter};

pub const APPLICATION_INDEX_UPDATED_EVENT: &str = "prism:application-index-updated";
const REFRESH_DEBOUNCE: Duration = Duration::from_millis(500);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationIndexUpdate {
    pub application_count: usize,
}

pub struct ApplicationWatcher {
    _watcher: Mutex<RecommendedWatcher>,
}

pub fn emit_update(app: &AppHandle, application_count: usize) {
    let _ = app.emit(
        APPLICATION_INDEX_UPDATED_EVENT,
        ApplicationIndexUpdate { application_count },
    );
}

pub fn start(app: AppHandle, index: ApplicationIndex) -> Result<ApplicationWatcher, String> {
    let (sender, receiver) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
        let Ok(event) = event else {
            return;
        };
        if matches!(
            event.kind,
            EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
        ) {
            let _ = sender.send(());
        }
    })
    .map_err(|error| format!("Could not create the application directory watcher: {error}"))?;

    for root in app_catalog::application_roots()
        .into_iter()
        .filter(|root| Path::new(root).exists())
    {
        #[cfg(any(target_os = "windows", target_os = "macos"))]
        let recursive_mode = RecursiveMode::Recursive;
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        let recursive_mode = RecursiveMode::NonRecursive;

        if let Err(error) = watcher.watch(&root, recursive_mode) {
            eprintln!(
                "Prism could not watch application directory {}: {error}",
                root.display()
            );
        }
    }

    thread::Builder::new()
        .name("prism-application-index".to_string())
        .spawn(move || {
            while receiver.recv().is_ok() {
                loop {
                    match receiver.recv_timeout(REFRESH_DEBOUNCE) {
                        Ok(()) => continue,
                        Err(mpsc::RecvTimeoutError::Timeout) => break,
                        Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    }
                }

                match index.refresh() {
                    Ok(application_count) => emit_update(&app, application_count),
                    Err(error) => {
                        eprintln!("Prism could not refresh its application index: {error}")
                    }
                }
            }
        })
        .map_err(|error| format!("Could not start the application directory watcher: {error}"))?;

    Ok(ApplicationWatcher {
        _watcher: Mutex::new(watcher),
    })
}
