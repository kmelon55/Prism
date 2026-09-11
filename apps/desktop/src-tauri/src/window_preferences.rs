use serde::{Deserialize, Serialize};
use std::{fs, path::Path, sync::Mutex};
use tauri::{Manager, State};

#[derive(Default)]
pub struct WindowPreferences(pub Mutex<()>);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WindowOptions {
    pub cycle: bool,
    pub reverse_cycle: bool,
    pub gap: u32,
    pub edge_gap: u32,
    pub almost_maximize: u32,
}
impl Default for WindowOptions {
    fn default() -> Self {
        Self {
            cycle: true,
            reverse_cycle: false,
            gap: 0,
            edge_gap: 0,
            almost_maximize: 90,
        }
    }
}
impl WindowOptions {
    fn validate(&self) -> Result<(), String> {
        if self.gap > 64 || self.edge_gap > 64 || !(50..=100).contains(&self.almost_maximize) {
            return Err("Invalid window management options.".into());
        }
        Ok(())
    }
}
fn read(path: &Path) -> Result<WindowOptions, String> {
    match fs::metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(WindowOptions::default()),
        Ok(meta) if meta.len() <= 4096 => (),
        _ => return Err("Could not read window management options.".into()),
    }
    let value: WindowOptions = serde_json::from_slice(
        &fs::read(path).map_err(|_| "Could not read window management options.")?,
    )
    .map_err(|_| "Invalid saved window management options.")?;
    value.validate()?;
    Ok(value)
}
pub fn load(app: &tauri::AppHandle) -> Result<WindowOptions, String> {
    read(
        &app.path()
            .app_config_dir()
            .map_err(|_| "Could not find settings folder.")?
            .join("window-management-v1.json"),
    )
}
#[tauri::command]
pub fn get_window_options(
    app: tauri::AppHandle,
    state: State<'_, WindowPreferences>,
) -> Result<WindowOptions, String> {
    let _guard = state.0.lock().map_err(|_| "Window options are busy.")?;
    load(&app)
}
#[tauri::command]
pub fn set_window_options(
    app: tauri::AppHandle,
    state: State<'_, WindowPreferences>,
    options: WindowOptions,
) -> Result<WindowOptions, String> {
    let _guard = state.0.lock().map_err(|_| "Window options are busy.")?;
    options.validate()?;
    let directory = app
        .path()
        .app_config_dir()
        .map_err(|_| "Could not find settings folder.")?;
    fs::create_dir_all(&directory).map_err(|_| "Could not create settings folder.")?;
    let path = directory.join("window-management-v1.json");
    // Never silently replace malformed existing settings.
    read(&path)?;
    let temporary = path.with_extension("tmp");
    fs::write(
        &temporary,
        serde_json::to_vec(&options).map_err(|_| "Could not encode window options.")?,
    )
    .and_then(|_| fs::rename(&temporary, &path))
    .map_err(|_| "Could not save window options.")?;
    Ok(options)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_invalid_options_and_preserve_malformed_data() {
        let mut options = WindowOptions::default();
        options.gap = 65;
        assert!(options.validate().is_err());
        let directory = std::env::temp_dir().join(format!(
            "prism-window-options-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("options.json");
        assert!(read(&path).unwrap().cycle);
        fs::write(&path, b"broken").unwrap();
        assert!(read(&path).is_err());
        assert_eq!(fs::read(path).unwrap(), b"broken");
        fs::remove_dir_all(directory).unwrap();
    }
}
