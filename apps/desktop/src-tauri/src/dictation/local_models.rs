//! Curated whisper.cpp models. Only verified, complete downloads become selectable.
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tauri::Manager;
use tokio::sync::Notify;

const REVISION: &str = "5359861c739e955e79d9a303bcbc70fb988958b1";
struct Model {
    id: &'static str,
    name: &'static str,
    description: &'static str,
    bytes: u64,
    sha256: &'static str,
}
const MODELS: &[Model] = &[
    Model {
        id: "large-v3-turbo-q5_0",
        name: "Whisper Large v3 Turbo · Q5",
        description:
            "Smaller download with 5-bit quantization. Supports Korean and multilingual dictation.",
        bytes: 574041195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    },
    Model {
        id: "large-v3-turbo",
        name: "Whisper Large v3 Turbo",
        description:
            "Fewer decoder layers than Large v3 for faster transcription. Supports Korean.",
        bytes: 1624555275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    },
    Model {
        id: "large-v3",
        name: "Whisper Large v3",
        description:
            "Full-size multilingual model. Needs more memory and processing time. Supports Korean.",
        bytes: 3095033483,
        sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
    },
    Model {
        id: "small",
        name: "Whisper Small",
        description: "A smaller multilingual model for Macs with limited memory. Supports Korean.",
        bytes: 487601967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    },
    Model {
        id: "medium",
        name: "Whisper Medium",
        description: "A multilingual model between Small and Large in size. Supports Korean.",
        bytes: 1533763059,
        sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
    },
];
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    model_id: String,
    downloaded: u64,
    total: u64,
}
struct Download {
    progress: DownloadProgress,
    cancel: Arc<Notify>,
}
static DOWNLOAD: Mutex<Option<Download>> = Mutex::new(None);
static INSTALLING: AtomicBool = AtomicBool::new(false);
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModel {
    id: String,
    name: String,
    description: String,
    bytes: u64,
    path: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModels {
    models: Vec<LocalModel>,
    whisper_path: Option<String>,
    can_install_engine: bool,
    installing_engine: bool,
    download: Option<DownloadProgress>,
}
fn model(id: &str) -> Result<&'static Model, String> {
    MODELS
        .iter()
        .find(|model| model.id == id)
        .ok_or_else(|| "Choose a supported local model.".into())
}
fn directory(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("dictation-models"))
}
fn model_path(dir: &Path, model: &Model) -> PathBuf {
    dir.join(format!("ggml-{}.bin", model.id))
}
fn complete(path: &Path, model: &Model) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file() && meta.len() == model.bytes)
}
fn executable(path: &str) -> bool {
    if !Path::new(path).is_absolute() {
        return false;
    }
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        false
    }
}
fn whisper_path(preferred: &str) -> Option<String> {
    [
        preferred,
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/opt/whisper.cpp/bin/whisper-cli",
        "/usr/local/opt/whisper.cpp/bin/whisper-cli",
    ]
    .into_iter()
    .find(|path| executable(path))
    .map(str::to_owned)
}
fn brew_path() -> Option<&'static str> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .into_iter()
        .find(|path| executable(path))
}
#[tauri::command]
pub fn dictation_local_models(
    app: tauri::AppHandle,
    preferred_whisper_path: String,
) -> Result<LocalModels, String> {
    let dir = directory(&app)?;
    Ok(LocalModels {
        models: MODELS
            .iter()
            .map(|model| {
                let path = model_path(&dir, model);
                LocalModel {
                    id: model.id.into(),
                    name: model.name.into(),
                    description: model.description.into(),
                    bytes: model.bytes,
                    path: complete(&path, model).then(|| path.to_string_lossy().into_owned()),
                }
            })
            .collect(),
        whisper_path: whisper_path(&preferred_whisper_path),
        can_install_engine: brew_path().is_some(),
        installing_engine: INSTALLING.load(Ordering::SeqCst),
        download: DOWNLOAD
            .lock()
            .map_err(|e| e.to_string())?
            .as_ref()
            .map(|job| job.progress.clone()),
    })
}
struct DownloadGuard;
impl Drop for DownloadGuard {
    fn drop(&mut self) {
        if let Ok(mut job) = DOWNLOAD.lock() {
            *job = None;
        }
    }
}
struct PartialFile(PathBuf);
impl Drop for PartialFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn verify_hash(bytes: u64, digest: &[u8], model: &Model) -> Result<(), String> {
    if bytes != model.bytes
        || digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
            != model.sha256
    {
        return Err("The model download is incomplete or damaged. Please retry.".into());
    }
    Ok(())
}
fn verify_existing(path: &Path, model: &Model) -> Result<(), String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut total = 0;
    let mut buf = [0; 128 * 1024];
    loop {
        let read = file.read(&mut buf).map_err(|e| e.to_string())?;
        if read == 0 {
            break;
        }
        total += read as u64;
        hash.update(&buf[..read]);
    }
    verify_hash(total, &hash.finalize(), model)
}
async fn download_to(dir: &Path, model: &'static Model) -> Result<String, String> {
    let target = model_path(dir, model);
    if complete(&target, model) {
        let existing = target.clone();
        if tauri::async_runtime::spawn_blocking(move || verify_existing(&existing, model))
            .await
            .map_err(|e| e.to_string())?
            .is_ok()
        {
            return Ok(target.to_string_lossy().into_owned());
        }
    }
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let partial = PartialFile(target.with_extension("bin.part"));
    // The process-wide guard owns this staging path; a crashed download is replaced on retry.
    if partial.0.exists() {
        fs::remove_file(&partial.0).map_err(|e| e.to_string())?;
    }
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&partial.0)
        .map_err(|e| e.to_string())?;
    let client = reqwest::Client::builder()
        .https_only(true)
        .connect_timeout(Duration::from_secs(30))
        .read_timeout(Duration::from_secs(60))
        .timeout(Duration::from_secs(7200))
        .build()
        .map_err(|e| e.to_string())?;
    let url = format!(
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/{REVISION}/ggml-{}.bin",
        model.id
    );
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?;
    if response
        .content_length()
        .is_some_and(|length| length != model.bytes)
    {
        return Err("The model download is incomplete or damaged. Please retry.".into());
    }
    let mut hash = Sha256::new();
    let mut total = 0;
    let mut last_update = Instant::now();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        total += chunk.len() as u64;
        if total > model.bytes {
            return Err("The model download is incomplete or damaged. Please retry.".into());
        }
        file.write_all(&chunk).map_err(|e| e.to_string())?;
        hash.update(&chunk);
        if last_update.elapsed() >= Duration::from_millis(150) || total == model.bytes {
            if let Some(job) = DOWNLOAD.lock().map_err(|e| e.to_string())?.as_mut() {
                job.progress.downloaded = total;
            }
            last_update = Instant::now();
        }
    }
    verify_hash(total, &hash.finalize(), model)?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    fs::rename(&partial.0, &target).map_err(|e| e.to_string())?;
    Ok(target.to_string_lossy().into_owned())
}
#[tauri::command]
pub async fn dictation_download_model(
    app: tauri::AppHandle,
    model_id: String,
) -> Result<String, String> {
    let model = model(&model_id)?;
    let dir = directory(&app)?;
    let cancel = Arc::new(Notify::new());
    {
        let mut job = DOWNLOAD.lock().map_err(|e| e.to_string())?;
        if job.is_some() {
            return Err("Another local model is downloading. Wait or cancel it first.".into());
        }
        *job = Some(Download {
            progress: DownloadProgress {
                model_id,
                downloaded: 0,
                total: model.bytes,
            },
            cancel: cancel.clone(),
        });
    }
    let _guard = DownloadGuard;
    tokio::select! {
        biased;
        _ = cancel.notified() => Err("Model download cancelled.".into()),
        result = download_to(&dir, model) => result,
    }
}
#[tauri::command]
pub fn dictation_cancel_model_download(model_id: String) -> Result<(), String> {
    if let Some(job) = DOWNLOAD.lock().map_err(|e| e.to_string())?.as_ref() {
        if job.progress.model_id == model_id {
            job.cancel.notify_one();
        }
    }
    Ok(())
}
struct InstallGuard;
impl Drop for InstallGuard {
    fn drop(&mut self) {
        INSTALLING.store(false, Ordering::SeqCst);
    }
}
#[tauri::command]
pub async fn dictation_install_whisper(app: tauri::AppHandle) -> Result<String, String> {
    if let Some(path) = whisper_path("") {
        return Ok(path);
    }
    let brew = brew_path()
        .ok_or("Install Homebrew or choose an existing whisper-cli in Advanced settings.")?;
    if INSTALLING.swap(true, Ordering::SeqCst) {
        return Err("Speech engine installation is already running.".into());
    }
    let _guard = InstallGuard;
    let dir = directory(&app)?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let log = File::create(dir.join("engine-install.log")).map_err(|e| e.to_string())?;
    let mut command = tokio::process::Command::new(brew);
    command
        .args(["install", "whisper.cpp"])
        .env("NONINTERACTIVE", "1")
        .env("HOMEBREW_NO_AUTO_UPDATE", "1")
        .env("HOMEBREW_NO_INSTALL_CLEANUP", "1")
        .stdin(std::process::Stdio::null())
        .stdout(log.try_clone().map_err(|e| e.to_string())?)
        .stderr(log)
        .kill_on_drop(true);
    let status = command.status().await.map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("Speech engine installation failed. Run brew install whisper.cpp in Terminal, then check again.".into());
    }
    whisper_path("").ok_or_else(|| {
        "The speech engine was not found. Choose whisper-cli in Advanced settings.".into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unlisted_names_and_paths() {
        for id in [
            "../large-v3",
            "https://example.com/model",
            "large-v3.en",
            "",
        ] {
            assert!(model(id).is_err());
        }
        for entry in MODELS {
            assert_eq!(model(entry.id).unwrap().bytes, entry.bytes);
            assert_eq!(entry.sha256.len(), 64);
        }
    }
    #[test]
    fn validates_bytes_and_checksum_independently() {
        let fixture = Model {
            id: "test",
            name: "test",
            description: "",
            bytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        };
        assert!(verify_hash(3, &Sha256::digest(b"abc"), &fixture).is_ok());
        assert!(verify_hash(2, &Sha256::digest(b"abc"), &fixture).is_err());
        assert!(verify_hash(3, &Sha256::digest(b"abd"), &fixture).is_err());
    }
    #[test]
    fn partial_downloads_are_not_ready_and_staging_is_cleaned() {
        let dir = std::env::temp_dir().join(format!("prism-model-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let target = model_path(&dir, &MODELS[0]);
        fs::write(&target, b"partial").unwrap();
        assert!(!complete(&target, &MODELS[0]));
        let staging = target.with_extension("bin.part");
        {
            let _guard = PartialFile(staging.clone());
            fs::write(&staging, b"partial").unwrap();
        }
        assert!(!staging.exists());
        assert!(target.exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
