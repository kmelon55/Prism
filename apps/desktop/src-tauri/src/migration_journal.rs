//! Durable recovery record written before applying a reviewed migration.
use serde_json::Value;
use std::{fs, io::Write, sync::Mutex};
use tauri::{Manager, State};

#[derive(Default)]
pub struct MigrationJournal(Mutex<()>);
const LIMIT: usize = 20 * 1024 * 1024;
fn validate(value: &Value) -> Result<(), String> {
    if value["version"] != 1
        || value["id"].as_str().is_none_or(|id| {
            id.len() != 36 || !id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
        })
        || value["changes"]
            .as_array()
            .is_none_or(|rows| rows.len() > 3000)
    {
        return Err("Invalid import recovery record.".into());
    }
    for change in value["changes"].as_array().unwrap() {
        let item = &change["item"];
        let valid_string = |value: &Value, max: usize| {
            value
                .as_str()
                .is_some_and(|text| text.len() <= max && !text.contains('\0'))
        };
        let category = item["category"].as_str().unwrap_or("");
        if !["pending", "applied", "failed", "undone"]
            .contains(&change["state"].as_str().unwrap_or(""))
            || !valid_string(&item["id"], 100)
            || !valid_string(&item["title"], 4096)
            || !valid_string(&item["value"], 128 * 1024)
            || (!change["before"].is_null() && !valid_string(&change["before"], 1024))
            || (!change["error"].is_null() && !valid_string(&change["error"], 8192))
        {
            return Err("Invalid import recovery record.".into());
        }
        match category {
            "hotkeys" | "aliases" if valid_string(&item["commandId"], 512) => (),
            "snippets" | "quicklinks" => {
                let entry = &item["entry"];
                if !valid_string(&entry["id"], 512)
                    || !valid_string(&entry["title"], 300)
                    || !valid_string(&entry["value"], 128 * 1024)
                    || !["snippet", "link"].contains(&entry["kind"].as_str().unwrap_or(""))
                    || (!entry["keyword"].is_null() && !valid_string(&entry["keyword"], 48))
                {
                    return Err("Invalid import recovery record.".into());
                }
            }
            _ => return Err("Invalid import recovery record.".into()),
        }
    }
    Ok(())
}
fn path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    Ok(app
        .path()
        .app_config_dir()
        .map_err(|_| "Could not find settings folder.")?
        .join("raycast-import-recovery-v1.json"))
}
fn read(path: &std::path::Path) -> Result<Option<Value>, String> {
    match fs::metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(meta) if meta.len() <= LIMIT as u64 => (),
        _ => return Err("Could not read import recovery record.".into()),
    }
    let value: Value = serde_json::from_slice(
        &fs::read(path).map_err(|_| "Could not read import recovery record.")?,
    )
    .map_err(|_| "Invalid import recovery record.")?;
    validate(&value)?;
    Ok(Some(value))
}
#[tauri::command]
pub fn raycast_read_journal(
    app: tauri::AppHandle,
    state: State<'_, MigrationJournal>,
) -> Result<Option<Value>, String> {
    let _guard = state.0.lock().map_err(|_| "Import recovery is busy.")?;
    read(&path(&app)?)
}
#[tauri::command]
pub fn raycast_write_journal(
    app: tauri::AppHandle,
    state: State<'_, MigrationJournal>,
    journal: Value,
    create: bool,
) -> Result<(), String> {
    let _guard = state.0.lock().map_err(|_| "Import recovery is busy.")?;
    validate(&journal)?;
    let path = path(&app)?;
    let existing = read(&path)?;
    if (create && existing.is_some())
        || (!create
            && existing
                .as_ref()
                .is_none_or(|old| old["id"] != journal["id"]))
    {
        return Err("Import recovery changed. Review it again.".into());
    }
    let bytes = serde_json::to_vec(&journal).map_err(|_| "Could not encode import recovery.")?;
    if bytes.len() > LIMIT {
        return Err("Import recovery is too large.".into());
    }
    fs::create_dir_all(path.parent().ok_or("Invalid recovery path.")?)
        .map_err(|_| "Could not create settings folder.")?;
    let temporary = path.with_extension("tmp");
    let mut options = fs::OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .map_err(|_| "Could not preserve import recovery.")?;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .and_then(|_| fs::rename(&temporary, &path))
        .map_err(|_| "Could not preserve import recovery.")?;
    Ok(())
}
#[tauri::command]
pub fn raycast_clear_journal(
    app: tauri::AppHandle,
    state: State<'_, MigrationJournal>,
    id: String,
) -> Result<(), String> {
    let _guard = state.0.lock().map_err(|_| "Import recovery is busy.")?;
    let path = path(&app)?;
    if read(&path)?.as_ref().is_none_or(|old| old["id"] != id) {
        return Err("Import recovery changed. Review it again.".into());
    }
    fs::remove_file(path).map_err(|_| "Could not clear import recovery.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_recovery_is_never_silently_discarded() {
        let directory = std::env::temp_dir().join(format!(
            "prism-journal-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("journal.json");
        assert!(read(&path).unwrap().is_none());
        fs::write(&path, b"corrupt").unwrap();
        assert!(read(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"corrupt");
        assert!(validate(&serde_json::json!({"version": 2, "id": "bad", "changes": []})).is_err());
        fs::remove_dir_all(directory).unwrap();
    }
}
