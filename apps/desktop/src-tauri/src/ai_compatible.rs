//! One explicitly configured Chat Completions server. Credentials are scoped to its exact base URL.
use crate::ai_key_session::KeySession;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};
use tauri::Manager;

const SERVICE: &str = "dev.prism.desktop.ai.compatible";
static OPERATIONS: Mutex<()> = Mutex::new(());
static SESSION: Mutex<Option<(String, KeySession)>> = Mutex::new(None);

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub base_url: String,
    pub has_key: bool,
}

pub fn normalize_base(input: &str) -> Result<String, String> {
    let raw = input.trim();
    if raw.is_empty() || raw.len() > 2048 || raw.chars().any(char::is_control) {
        return Err("Enter a valid API base URL.".into());
    }
    let mut url = reqwest::Url::parse(raw).map_err(|_| "Enter a valid API base URL.")?;
    if !["http", "https"].contains(&url.scheme())
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(
            "Use an HTTP(S) base URL without credentials, query parameters or fragments.".into(),
        );
    }
    let path = url.path().trim_end_matches('/').to_owned();
    if path.ends_with("/chat/completions") || path.ends_with("/models") {
        return Err("Enter the API base URL, such as http://localhost:11434/v1.".into());
    }
    url.set_path(&format!("{path}/"));
    Ok(url.to_string())
}

fn path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|_| "Could not find AI settings.")?
        .join("ai-compatible-v1.json"))
}
fn read(path: &Path) -> Result<Connection, String> {
    match fs::metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Connection::default()),
        Ok(meta) if meta.len() <= 8192 => (),
        _ => return Err("Could not read the custom API connection.".into()),
    }
    let value: Connection = serde_json::from_slice(
        &fs::read(path).map_err(|_| "Could not read the custom API connection.")?,
    )
    .map_err(|_| "The custom API connection is malformed.")?;
    normalize_base(&value.base_url)?;
    Ok(value)
}
fn write(path: &Path, value: &Connection) -> Result<(), String> {
    fs::create_dir_all(path.parent().ok_or("Could not find AI settings.")?)
        .map_err(|_| "Could not create AI settings.")?;
    let temp = path.with_extension("tmp");
    fs::write(
        &temp,
        serde_json::to_vec(value).map_err(|_| "Could not save the custom API connection.")?,
    )
    .and_then(|_| fs::rename(temp, path))
    .map_err(|_| "Could not save the custom API connection.".into())
}

#[tauri::command]
pub fn ai_get_compatible(app: tauri::AppHandle) -> Result<Connection, String> {
    let _guard = OPERATIONS
        .lock()
        .map_err(|_| "Could not read the custom API connection.")?;
    read(&path(&app)?)
}

#[tauri::command]
pub async fn ai_save_compatible(
    app: tauri::AppHandle,
    base_url: String,
    key: Option<String>,
) -> Result<Connection, String> {
    let base_url = normalize_base(&base_url)?;
    let key = key.map(|s| zeroize::Zeroizing::new(s.trim().to_owned()));
    if key
        .as_ref()
        .is_some_and(|k| k.len() > 4096 || !k.bytes().all(|b| b.is_ascii_graphic()))
    {
        return Err("Enter an API key without spaces or line breaks.".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = OPERATIONS
            .lock()
            .map_err(|_| "Could not save the custom API connection.")?;
        let path = path(&app)?;
        let previous = read(&path)?;
        let has_key = key
            .as_ref()
            .map_or(previous.base_url == base_url && previous.has_key, |key| {
                !key.is_empty()
            });
        if let Some(key) = key.as_ref().filter(|key| !key.is_empty()) {
            #[cfg(target_os = "macos")]
            crate::keychain::save(SERVICE, &base_url, key.as_bytes())
                .map_err(|_| "Could not save the custom API key in Keychain.")?;
            #[cfg(not(target_os = "macos"))]
            prism_desktop_platform::credentials::save(SERVICE, &base_url, key.as_bytes())?;
        }
        let value = Connection {
            base_url: base_url.clone(),
            has_key,
        };
        write(&path, &value)?;
        let mut cache = SESSION
            .lock()
            .map_err(|_| "Could not update custom API authorization.")?;
        if let Some(key) = key {
            let mut session = KeySession::default();
            if !key.is_empty() {
                session.replace(key.as_bytes().to_vec());
            }
            *cache = Some((base_url, session));
        } else if cache.as_ref().is_some_and(|(url, _)| url != &base_url) {
            *cache = None;
        }
        Ok(value)
    })
    .await
    .map_err(|_| "Could not save the custom API connection.".to_owned())?
}

pub async fn target(
    app: &tauri::AppHandle,
    suffix: &str,
    allow_prompt: bool,
) -> Result<(String, Option<reqwest::header::HeaderValue>), String> {
    let app = app.clone();
    let (base, key) = tauri::async_runtime::spawn_blocking(move || {
        let _guard = OPERATIONS
            .lock()
            .map_err(|_| "Could not read the custom API connection.")?;
        let connection = read(&path(&app)?)?;
        let base = normalize_base(&connection.base_url)?;
        let key = if connection.has_key {
            let mut cache = SESSION
                .lock()
                .map_err(|_| "Could not read custom API authorization.")?;
            if cache.as_ref().is_none_or(|(url, _)| url != &base) {
                *cache = Some((base.clone(), KeySession::default()));
            }
            let session = &mut cache.as_mut().unwrap().1;
            let read = || {
                #[cfg(target_os = "macos")]
                {
                    crate::keychain::read(SERVICE, &base, allow_prompt)
                }
                #[cfg(not(target_os = "macos"))]
                {
                    prism_desktop_platform::credentials::read(SERVICE, &base)
                }
            };
            let key = (if allow_prompt {
                session.load(read)
            } else {
                session.load_silent(read)
            })?
            .ok_or("The saved custom API key is unavailable. Save it again in AI settings.")?;
            Some(key)
        } else {
            None
        };
        Ok::<_, String>((base, key))
    })
    .await
    .map_err(|_| "Could not read custom API authorization.".to_owned())??;
    let authorization = key
        .map(|key| {
            let mut header = reqwest::header::HeaderValue::from_bytes(
                &[b"Bearer ".as_slice(), key.as_slice()].concat(),
            )
            .map_err(|_| "Check the custom API key.".to_owned())?;
            header.set_sensitive(true);
            Ok::<_, String>(header)
        })
        .transpose()?;
    Ok((format!("{base}{suffix}"), authorization))
}

#[tauri::command]
pub async fn ai_unlock_compatible(app: tauri::AppHandle) -> Result<(), String> {
    target(&app, "models", true).await.map(|_| ())
}

#[tauri::command]
pub async fn ai_list_compatible_models(
    app: tauri::AppHandle,
) -> Result<Vec<crate::ai::AiModel>, String> {
    let (url, authorization) = target(&app, "models", false).await?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|_| "Could not connect to the custom API.")?;
    let mut request = client.get(url);
    if let Some(header) = authorization {
        request = request.header(reqwest::header::AUTHORIZATION, header);
    }
    let mut response = request
        .send()
        .await
        .map_err(|_| "Could not load models. Check the server or enter a model ID manually.")?;
    if !response.status().is_success() {
        return Err(format!("Model lookup failed (HTTP {}). Enter a model ID manually if this server has no model catalog.", response.status().as_u16()));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Could not read the model catalog.")?
    {
        if bytes.len() + chunk.len() > 1_048_576 {
            return Err("The model catalog is too large.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let value = serde_json::from_slice(&bytes).map_err(|_| "The model catalog is malformed.")?;
    crate::ai::parse_models(crate::ai::Provider::Compatible, &value)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn base_urls_preserve_prefixes_and_reject_ambiguous_targets() {
        assert_eq!(
            normalize_base(" http://localhost:11434/v1 ").unwrap(),
            "http://localhost:11434/v1/"
        );
        assert_eq!(
            normalize_base("https://example.test/proxy/v1/").unwrap(),
            "https://example.test/proxy/v1/"
        );
        for input in [
            "",
            "file:///tmp/key",
            "https://key@example.test/v1",
            "https://example.test/v1?key=secret",
            "https://example.test/v1#key",
            "https://example.test/v1/chat/completions",
            "https://example.test/v1/models",
        ] {
            assert!(normalize_base(input).is_err(), "{input}");
        }
    }
    #[test]
    fn connection_persists_without_credentials_and_rejects_corruption() {
        let dir = std::env::temp_dir().join(format!(
            "prism-compatible-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = dir.join("connection.json");
        assert!(read(&path).unwrap().base_url.is_empty());
        write(
            &path,
            &Connection {
                base_url: "http://localhost:11434/v1/".into(),
                has_key: false,
            },
        )
        .unwrap();
        assert_eq!(read(&path).unwrap().base_url, "http://localhost:11434/v1/");
        fs::write(&path, "broken").unwrap();
        assert!(read(&path).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
}
