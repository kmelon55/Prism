//! Whisp-backed native dictation. Audio and transcripts are temporary; keys stay in Keychain.
pub mod catalog;
pub mod processing;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};
use tauri::{Emitter, Manager};

const SETTINGS: &str = "dictation-v1.json";
const KEY_SERVICE: &str = "dev.prism.desktop.ai";
static APP: OnceLock<tauri::AppHandle> = OnceLock::new();
static STATUS: OnceLock<Mutex<Value>> = OnceLock::new();
static SETTINGS_LOCK: Mutex<()> = Mutex::new(());
#[cfg(target_os = "macos")]
fn key_sessions(
) -> &'static Mutex<std::collections::HashMap<&'static str, crate::ai_key_session::KeySession>> {
    static SESSIONS: OnceLock<
        Mutex<std::collections::HashMap<&'static str, crate::ai_key_session::KeySession>>,
    > = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecordingBinding {
    mode: String,
    kind: String,
    key_code: u32,
    modifiers: u32,
    label: String,
}
impl RecordingBinding {
    fn custom(key_code: u32, label: &str) -> Self {
        Self {
            mode: "custom".into(),
            kind: "keyCombination".into(),
            key_code,
            modifiers: 0,
            label: label.into(),
        }
    }
    fn cancel() -> Self {
        Self::custom(53, "Esc")
    }
    fn send() -> Self {
        Self::custom(36, "Return")
    }
    fn copy() -> Self {
        Self {
            mode: "disabled".into(),
            ..Self::custom(0, "")
        }
    }
    fn paste() -> Self {
        Self {
            mode: "sameAsPrimary".into(),
            ..Self::custom(0, "")
        }
    }
}
fn default_delivery() -> String {
    "paste".into()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DictationSettings {
    #[serde(default)]
    enhancement_mode: Option<String>,
    #[serde(default)]
    cleanup_model: Option<processing::Selection>,
    #[serde(default)]
    prompt_model: Option<processing::Selection>,
    #[serde(default = "processing::cleanup_default")]
    cleanup_instruction: String,
    #[serde(default = "processing::prompt_default")]
    prompt_instruction: String,
    #[serde(default)]
    refine_text: bool,
    #[serde(default)]
    processing_model: Option<processing::Selection>,
    provider: String,
    model: String,
    #[serde(rename = "baseURL")]
    base_url: String,
    language: String,
    prompt: String,
    vocabulary: Vec<String>,
    whisper_path: String,
    model_path: String,
    ui_language: String,
    #[serde(default = "default_true")]
    show_recording_shortcut_hints: bool,
    #[serde(default = "default_true")]
    show_transcription_status: bool,
    #[serde(default = "default_delivery")]
    default_delivery: String,
    #[serde(default = "RecordingBinding::cancel")]
    recording_cancel_shortcut: RecordingBinding,
    #[serde(default = "RecordingBinding::copy")]
    recording_copy_shortcut: RecordingBinding,
    #[serde(default = "RecordingBinding::paste")]
    recording_paste_shortcut: RecordingBinding,
    #[serde(default = "RecordingBinding::send")]
    recording_paste_and_enter_shortcut: RecordingBinding,
}
fn default_true() -> bool {
    true
}
impl Default for DictationSettings {
    fn default() -> Self {
        Self {
            enhancement_mode: Some("off".into()),
            cleanup_model: None,
            prompt_model: None,
            cleanup_instruction: processing::cleanup_default(),
            prompt_instruction: processing::prompt_default(),
            refine_text: false,
            processing_model: None,
            provider: "local".into(),
            model: "".into(),
            base_url: "".into(),
            language: "auto".into(),
            prompt: "".into(),
            vocabulary: vec![],
            whisper_path: if Path::new("/opt/homebrew/bin/whisper-cli").exists() {
                "/opt/homebrew/bin/whisper-cli"
            } else {
                "/usr/local/bin/whisper-cli"
            }
            .into(),
            model_path: "".into(),
            ui_language: "ko".into(),
            show_recording_shortcut_hints: true,
            show_transcription_status: true,
            default_delivery: default_delivery(),
            recording_cancel_shortcut: RecordingBinding::cancel(),
            recording_copy_shortcut: RecordingBinding::copy(),
            recording_paste_shortcut: RecordingBinding::paste(),
            recording_paste_and_enter_shortcut: RecordingBinding::send(),
        }
    }
}
impl DictationSettings {
    fn upgrade(&mut self) {
        if self.enhancement_mode.is_none() {
            self.enhancement_mode = Some(if self.refine_text { "cleanup" } else if self.processing_model.is_some() { "prompt" } else { "off" }.into());
            self.cleanup_model = self.processing_model.clone();
            self.prompt_model = self.processing_model.clone();
        }
        self.refine_text = matches!(self.enhancement_mode.as_deref(), Some("cleanup" | "both"));
    }
    fn validate(&self) -> Result<(), String> {
        if let Some(mode) = &self.enhancement_mode { if !["off", "cleanup", "prompt", "both"].contains(&mode.as_str()) { return Err("Choose a dictation enhancement.".into()); } }
        for model in [&self.processing_model, &self.cleanup_model, &self.prompt_model].into_iter().flatten() { model.validate()?; }
        processing::instruction("cleanup", Some(&self.cleanup_instruction))?;
        processing::instruction("prompt", Some(&self.prompt_instruction))?;
        if !["copy", "paste"].contains(&self.default_delivery.as_str()) {
            return Err("기본 결과 동작을 선택하세요.".into());
        }
        let bindings = [
            &self.recording_cancel_shortcut,
            &self.recording_paste_shortcut,
            &self.recording_paste_and_enter_shortcut,
            &self.recording_copy_shortcut,
        ];
        for (index, binding) in bindings.iter().enumerate() {
            if !["custom", "disabled", "sameAsPrimary"].contains(&binding.mode.as_str())
                || (binding.mode == "sameAsPrimary" && index != 1)
                || ![
                    "keyCombination",
                    "singleControl",
                    "singleOption",
                    "singleShift",
                    "singleCommand",
                ]
                .contains(&binding.kind.as_str())
                || binding.key_code > 126
                || binding.modifiers & !6912 != 0
                || binding.label.len() > 64
                || (binding.mode == "custom" && binding.label.trim().is_empty())
                || binding.label.chars().any(char::is_control)
            {
                return Err("녹음 단축키 설정이 올바르지 않습니다.".into());
            }
            if binding.mode == "custom"
                && bindings[..index].iter().any(|other| {
                    other.mode == "custom"
                        && other.kind == binding.kind
                        && (binding.kind != "keyCombination"
                            || (other.key_code == binding.key_code
                                && other.modifiers == binding.modifiers))
                })
            {
                return Err("녹음 동작마다 다른 단축키를 지정하세요.".into());
            }
        }

        if !["local", "openai", "vercel", "groq", "xai", "custom"].contains(&self.provider.as_str())
        {
            return Err("지원하지 않는 STT 제공자입니다.".into());
        }
        if self.model.len() > 200
            || self.prompt.len() > 8_000
            || self.vocabulary.len() > 100
            || self
                .vocabulary
                .iter()
                .any(|word| word.len() > 200 || word.contains(['\r', '\n', '\0']))
            || self.whisper_path.len() > 4096
            || self.model_path.len() > 4096
            || self.whisper_path.contains('\0')
            || self.model_path.contains('\0')
            || !["ko", "en"].contains(&self.ui_language.as_str())
            || self.language.is_empty()
            || self.language.len() > 16
            || !self
                .language
                .bytes()
                .all(|c| c.is_ascii_alphabetic() || c == b'-')
        {
            return Err("받아쓰기 설정 값이 올바르지 않습니다.".into());
        }
        if self.provider != "local" {
            if self.model.is_empty()
                || !self.model.bytes().all(|b| b.is_ascii_graphic())
                || self.model.to_ascii_lowercase().contains("realtime")
                || self.model.ends_with("-live")
                || (self.provider == "openai" && self.model.contains("diarize"))
            {
                return Err("파일 전사를 지원하는 STT 모델을 선택하세요.".into());
            }
            let url =
                reqwest::Url::parse(&self.base_url).map_err(|_| "올바른 API URL을 입력하세요.")?;
            let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
            if self.base_url.len() > 2048
                || !(url.scheme() == "https" || (url.scheme() == "http" && local))
                || !url.username().is_empty()
                || url.password().is_some()
                || url.query().is_some()
                || url.fragment().is_some()
                || url.host_str().is_none()
            {
                return Err("HTTPS URL 또는 로컬 HTTP 주소를 입력하세요. 인증 정보와 쿼리는 URL에 넣지 마세요.".into());
            }
            let expected = match self.provider.as_str() {
                "openai" => Some("https://api.openai.com/v1"),
                "vercel" => Some("https://ai-gateway.vercel.sh/v4/ai"),
                "groq" => Some("https://api.groq.com/openai/v1"),
                "xai" => Some("https://api.x.ai/v1"),
                _ => None,
            };
            if expected.is_some_and(|expected| self.base_url.trim_end_matches('/') != expected) {
                return Err("제공자 API 주소가 올바르지 않습니다. 다른 서버는 호환 서버 제공자를 선택하세요.".into());
            }
        }
        Ok(())
    }
    fn preflight(&self) -> Result<(), String> {
        self.validate()?;
        if self.provider == "local" {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let executable = fs::metadata(&self.whisper_path)
                    .map_err(|_| "whisper.cpp 실행 파일을 선택하세요.")?;
                if !Path::new(&self.whisper_path).is_absolute()
                    || !executable.is_file()
                    || executable.permissions().mode() & 0o111 == 0
                {
                    return Err("실행 가능한 whisper.cpp 파일을 선택하세요.".into());
                }
            }
            if !Path::new(&self.model_path).is_absolute() || !Path::new(&self.model_path).is_file()
            {
                return Err(
                    "로컬 Whisper 모델 파일을 선택하세요. Whisp 모델을 그대로 사용할 수 있습니다."
                        .into(),
                );
            }
        }
        Ok(())
    }
}
fn settings_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_config_dir()
        .map_err(|_| "설정 경로를 찾지 못했습니다.")?
        .join(SETTINGS))
}
fn read_settings(path: &Path) -> Result<DictationSettings, String> {
    match fs::metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(DictationSettings::default())
        }
        Ok(meta) if meta.len() <= 65_536 => (),
        _ => return Err("받아쓰기 설정을 읽지 못했습니다.".into()),
    }
    let mut settings: DictationSettings =
        serde_json::from_slice(&fs::read(path).map_err(|_| "설정을 읽지 못했습니다.")?)
            .map_err(|_| "받아쓰기 설정 형식이 올바르지 않습니다.")?;
    settings.upgrade();
    settings.validate()?;
    Ok(settings)
}
#[tauri::command]
pub fn dictation_get_settings(app: tauri::AppHandle) -> Result<DictationSettings, String> {
    let _lock = SETTINGS_LOCK.lock().map_err(|_| "설정이 사용 중입니다.")?;
    read_settings(&settings_path(&app)?)
}
#[tauri::command]
pub fn dictation_save_settings(
    app: tauri::AppHandle,
    mut settings: DictationSettings,
) -> Result<DictationSettings, String> {
    let _lock = SETTINGS_LOCK.lock().map_err(|_| "설정이 사용 중입니다.")?;
    settings.upgrade();
    settings.validate()?;
    let primary_shortcuts = app.try_state::<crate::shortcut::GlobalShortcutManager>()
        .map(|manager| [manager.dictation_shortcut_label(), manager.prompt_shortcut_label()]).unwrap_or_default();
    for primary in primary_shortcuts.into_iter().flatten() {
        let compact = |label: &str| label.replace(' ', "").to_lowercase();
        if [
            &settings.recording_cancel_shortcut,
            &settings.recording_paste_shortcut,
            &settings.recording_paste_and_enter_shortcut,
            &settings.recording_copy_shortcut,
        ]
        .iter()
        .any(|binding| binding.mode == "custom" && compact(&binding.label) == compact(&primary))
        {
            return Err(
                "녹음 시작 단축키와 겹칩니다. 붙여넣기는 ‘녹음 시작과 동일’을 선택하세요.".into(),
            );
        }
    }
    let path = settings_path(&app)?;
    fs::create_dir_all(path.parent().ok_or("설정 경로를 찾지 못했습니다.")?)
        .map_err(|_| "설정 폴더를 만들지 못했습니다.")?;
    let temp = path.with_extension("tmp");
    fs::write(
        &temp,
        serde_json::to_vec(&settings).map_err(|_| "설정을 저장하지 못했습니다.")?,
    )
    .and_then(|_| fs::rename(&temp, &path))
    .map_err(|_| "받아쓰기 설정을 저장하지 못했습니다.")?;
    let _ = app.emit("prism:dictation-settings-changed", ());
    Ok(settings)
}
fn shared_provider(provider: &str) -> Option<crate::ai::Provider> {
    match provider {
        "openai" => Some(crate::ai::Provider::Openai),
        "vercel" => Some(crate::ai::Provider::Vercel),
        _ => None,
    }
}
fn key_account(provider: &str) -> Result<&'static str, String> {
    match provider {
        "groq" => Ok("dictation-groq"),
        "xai" => Ok("dictation-xai"),
        "custom" => Ok("dictation-custom"),
        _ => Err("지원하지 않는 API 키 제공자입니다.".into()),
    }
}
#[tauri::command]
pub async fn dictation_key_status(provider: String) -> Result<bool, String> {
    dictation_key_info(provider)
        .await
        .map(|info| info.configured)
}
#[tauri::command]
pub async fn dictation_key_info(provider: String) -> Result<crate::ai::KeyInfo, String> {
    if let Some(provider) = shared_provider(&provider) {
        return crate::ai::ai_key_info(provider).await;
    }
    let account = key_account(&provider)?;
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let mut sessions = key_sessions()
                .lock()
                .map_err(|_| "키 상태를 읽지 못했습니다.")?;
            let session = sessions.entry(account).or_default();
            if let Ok(key) = session.load_silent(|| crate::keychain::read(KEY_SERVICE, account, false)) {
                return Ok(crate::ai::key_info(key.as_ref().map(|key| key.as_slice())));
            }
            Ok(crate::ai::KeyInfo {
                configured: crate::keychain::exists(KEY_SERVICE, account)
                    .map_err(|_| "키 저장 상태를 확인하지 못했습니다.")?,
                masked_key: None,
                unlocked: false,
            })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = account;
            Err("받아쓰기는 현재 macOS에서 지원합니다.".into())
        }
    })
    .await
    .map_err(|_| "키체인 작업을 완료하지 못했습니다.")?
}
#[tauri::command]
pub async fn dictation_unlock_key(provider: String) -> Result<crate::ai::KeyInfo, String> {
    if let Some(provider) = shared_provider(&provider) {
        return crate::ai::ai_unlock_key(provider).await;
    }
    let account = key_account(&provider)?;
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let mut sessions = key_sessions().lock().map_err(|_| "키 상태를 읽지 못했습니다.")?;
            let session = sessions.entry(account).or_default();
            session.allow_retry();
            let key = session.load(|| crate::keychain::read(KEY_SERVICE, account, true))?;
            Ok(crate::ai::key_info(key.as_ref().map(|key| key.as_slice())))
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = account;
            Err("키 저장은 현재 macOS에서 지원합니다.".into())
        }
    }).await.map_err(|_| "키체인 작업을 완료하지 못했습니다.")?
}
#[tauri::command]
pub async fn dictation_save_key(
    provider: String,
    key: String,
) -> Result<crate::ai::KeyInfo, String> {
    if let Some(provider) = shared_provider(&provider) {
        return crate::ai::ai_save_key(provider, key).await;
    }
    let account = key_account(&provider)?;
    let key = zeroize::Zeroizing::new(key.trim().to_string());
    if key.is_empty() || key.len() > 4096 || !key.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("공백이나 줄바꿈이 없는 API 키를 입력하세요.".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let mut sessions = key_sessions()
                .lock()
                .map_err(|_| "키 상태를 읽지 못했습니다.")?;
            crate::keychain::save(
                KEY_SERVICE,
                account,
                key.as_bytes(),
            )
            .map_err(|_| "API 키를 저장하지 못했습니다.")?;
            sessions
                .entry(account)
                .or_default()
                .replace(key.as_bytes().to_vec());
            Ok(crate::ai::key_info(Some(key.as_bytes())))
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (account, key);
            Err("키 저장은 현재 macOS에서 지원합니다.".into())
        }
    })
    .await
    .map_err(|_| "키체인 작업을 완료하지 못했습니다.")?
}
#[tauri::command]
pub async fn dictation_delete_key(provider: String) -> Result<(), String> {
    if let Some(provider) = shared_provider(&provider) {
        return crate::ai::ai_delete_key(provider).await;
    }
    let account = key_account(&provider)?;
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let mut sessions = key_sessions()
                .lock()
                .map_err(|_| "키 상태를 읽지 못했습니다.")?;
            match crate::keychain::delete(KEY_SERVICE, account) {
                Ok(()) => (),
                Err(error) if error.code() == -25300 => (),
                Err(_) => return Err("키를 삭제하지 못했습니다.".into()),
            }
            sessions.remove(account);
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = account;
            Err("키 저장은 현재 macOS에서 지원합니다.".into())
        }
    })
    .await
    .map_err(|_| "키체인 작업을 완료하지 못했습니다.")?
}
fn read_provider_key(provider: &str) -> Result<zeroize::Zeroizing<Vec<u8>>, String> {
    Ok(if provider == "local" {
        zeroize::Zeroizing::new(Vec::new())
    } else if let Some(provider) = shared_provider(provider) {
        crate::ai::read_key(provider)?.ok_or("받아쓰기 설정에서 API 키를 저장하세요.")?
    } else {
        #[cfg(target_os = "macos")]
        {
            let account = key_account(provider)?;
            key_sessions()
                .lock()
                .map_err(|_| "키 상태를 읽지 못했습니다.")?
                .entry(account)
                .or_default()
                .load(|| crate::keychain::read(KEY_SERVICE, account, true))?
                .ok_or("받아쓰기 설정에서 API 키를 저장하세요.")?
        }
        #[cfg(not(target_os = "macos"))]
        {
            return Err("받아쓰기는 현재 macOS에서 지원합니다.".into());
        }
    })
}
fn overlay_configuration(
    app: &tauri::AppHandle,
    settings: DictationSettings,
) -> Result<Value, String> {
    let mut value = serde_json::to_value(settings).map_err(|_| "설정을 준비하지 못했습니다.")?;
    value["primaryShortcutLabel"] = app
        .try_state::<crate::shortcut::GlobalShortcutManager>()
        .and_then(|manager| manager.dictation_shortcut_label())
        .map(Value::String)
        .unwrap_or(Value::Null);
    value["primaryDoubleModifier"] = app
        .try_state::<crate::shortcut::GlobalShortcutManager>()
        .and_then(|manager| manager.dictation_double_modifier())
        .map(Value::from)
        .unwrap_or(Value::Null);
    Ok(value)
}
fn configuration(app: &tauri::AppHandle, prompt_mode: bool) -> Result<zeroize::Zeroizing<String>, String> {
    let settings = dictation_get_settings(app.clone())?;
    settings.preflight()?;
    if prompt_mode && !matches!(settings.enhancement_mode.as_deref(), Some("prompt" | "both")) { return Err("Enable prompt structuring first.".into()); }
    let (processing_model, processing_prompt) = if prompt_mode { (settings.prompt_model.clone(), settings.prompt_instruction.clone()) } else { (settings.cleanup_model.clone(), settings.cleanup_instruction.clone()) };
    if prompt_mode && processing_model.is_none() { return Err("Choose a text processing model.".into()); }
    let key = read_provider_key(&settings.provider)?;
    // This JSON crosses an in-process FFI boundary only, never IPC or disk.
    let mut value = overlay_configuration(app, settings)?;
    value["processingModel"] = serde_json::to_value(processing_model).map_err(|_| "Invalid processing model.")?;
    value["processingPrompt"] = Value::String(processing_prompt);
    if prompt_mode {
        value["primaryShortcutLabel"] = app.try_state::<crate::shortcut::GlobalShortcutManager>().and_then(|m| m.prompt_shortcut_label()).map(Value::String).unwrap_or(Value::Null);
        value["primaryDoubleModifier"] = app.try_state::<crate::shortcut::GlobalShortcutManager>().and_then(|m| m.prompt_double_modifier()).map(Value::from).unwrap_or(Value::Null);
    }
    if matches!(value["enhancementMode"].as_str(), Some("prompt" | "both")) {
        let modifiers = app.try_state::<crate::shortcut::GlobalShortcutManager>().map(|m| [m.dictation_double_modifier(), m.prompt_double_modifier()].into_iter().flatten().collect::<Vec<_>>()).unwrap_or_default();
        value["additionalDoubleModifiers"] = serde_json::json!(modifiers);
    }
    value["apiKey"] = Value::String(
        String::from_utf8(key.to_vec()).map_err(|_| "API 키 형식이 올바르지 않습니다.")?,
    );
    let result = zeroize::Zeroizing::new(value.to_string());
    if let Some(Value::String(key)) = value.get_mut("apiKey") {
        use zeroize::Zeroize;
        key.zeroize();
    }
    Ok(result)
}
#[cfg(target_os = "macos")]
extern "C" {
    fn prism_dictation_init(callback: extern "C" fn(*const std::ffi::c_char));
    fn prism_dictation_set_messages(json: *const std::ffi::c_char);
    fn prism_dictation_set_ui_language(locale: *const std::ffi::c_char);
    fn prism_dictation_toggle(pid: i32);
    fn prism_dictation_prompt_toggle(pid: i32);
    fn prism_dictation_action(action: i32);
    fn prism_dictation_preview(json: *const std::ffi::c_char);
    fn prism_dictation_configure(json: *const std::ffi::c_char, session: u64, failed: bool);
}
#[cfg(target_os = "macos")]
extern "C" fn native_event(pointer: *const std::ffi::c_char) {
    if pointer.is_null() {
        return;
    }
    let Ok(event) =
        serde_json::from_slice::<Value>(unsafe { std::ffi::CStr::from_ptr(pointer) }.to_bytes())
    else {
        return;
    };
    let Some(app) = APP.get() else {
        return;
    };
    // Internal events may contain dictated text. Never broadcast or cache them in frontend status.
    if event["action"] == "process" { processing::start(app.clone(), event); return; }
    if event["action"] == "usage-start" || event["action"] == "usage-finish" { processing::transcription(app, &event); return; }
    if event["phase"] == "idle" || event["phase"] == "error" { processing::cancel(); }
    if let Ok(mut state) = STATUS.get_or_init(|| Mutex::new(json!({}))).lock() {
        *state = event.clone();
    }
    let _ = app.emit("prism:dictation-state", &event);
    if event["action"] == "configure" {
        let session = event["session"].as_u64().unwrap_or_default();
        let prompt_mode = event["processingMode"] == "prompt";
        let app = app.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let (text, failed) = match configuration(&app, prompt_mode) {
                Ok(value) => (value, false),
                Err(message) => (zeroize::Zeroizing::new(message), true),
            };
            let _ = app.run_on_main_thread(move || {
                if let Ok(cstring) = std::ffi::CString::new(text.as_bytes()) {
                    unsafe { prism_dictation_configure(cstring.as_ptr(), session, failed) };
                    use zeroize::Zeroize;
                    let mut bytes = cstring.into_bytes_with_nul();
                    bytes.zeroize();
                }
            });
        });
    }
}
pub fn shutdown() {
    #[cfg(target_os = "macos")]
    unsafe {
        prism_dictation_action(0);
    }
}
pub fn install(app: &tauri::AppHandle) {
    let _ = APP.set(app.clone());
    #[cfg(target_os = "macos")]
    unsafe {
        let messages = std::ffi::CString::new(include_str!("../../src/locales/messages.json"))
            .expect("The message catalog cannot contain a literal NUL");
        prism_dictation_set_messages(messages.as_ptr());
        prism_dictation_init(native_event);
    }
}
#[tauri::command]
pub fn dictation_set_ui_language(app: tauri::AppHandle, locale: String) -> Result<(), String> {
    if !matches!(locale.as_str(), "en" | "ko") {
        return Err("Unsupported interface language.".into());
    }
    #[cfg(target_os = "macos")]
    {
        let locale = std::ffi::CString::new(locale).map_err(|_| "Invalid interface language.")?;
        app.run_on_main_thread(move || unsafe { prism_dictation_set_ui_language(locale.as_ptr()) })
            .map_err(|_| "Could not update the dictation language.".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(())
    }
}
#[tauri::command]
pub fn dictation_toggle(app: tauri::AppHandle) -> Result<(), String> {
    toggle_mode(app, false)
}
#[tauri::command]
pub fn dictation_prompt_toggle(app: tauri::AppHandle) -> Result<(), String> {
    toggle_mode(app, true)
}
fn toggle_mode(app: tauri::AppHandle, prompt_mode: bool) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let host = app.clone();
        app.run_on_main_thread(move || {
            let pid = if host
                .get_webview_window("main")
                .is_some_and(|window| window.is_focused().unwrap_or(false))
            {
                host.state::<crate::window_management::WindowManager>()
                    .target_pid
                    .load(std::sync::atomic::Ordering::Acquire)
            } else {
                0
            };
            unsafe {
                if prompt_mode { prism_dictation_prompt_toggle(pid); } else { prism_dictation_toggle(pid); }
            }
            // Capture AX before hiding Prism, and keep the panel nonactivating.
            if let Some(window) = host.get_webview_window("main") {
                let _ = window.hide();
            }
        })
        .map_err(|_| "받아쓰기를 시작하지 못했습니다.".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Err("받아쓰기는 현재 macOS에서 지원합니다.".into())
    }
}
#[tauri::command]
pub async fn dictation_action(
    app: tauri::AppHandle,
    action: String,
    preview_settings: Option<DictationSettings>,
) -> Result<Value, String> {
    #[cfg(target_os = "macos")]
    {
        if action == "microphoneSettings" {
            std::process::Command::new("/usr/bin/open")
                .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                .spawn()
                .map_err(|_| "마이크 설정을 열지 못했습니다.")?;
        } else {
            let code = match action.as_str() {
                "cancel" => 0,
                "preview" => 1,
                "copy" => 2,
                "copyOriginal" => 5,
                "status" => 3,
                "microphoneRequest" => 4,
                _ => return Err("알 수 없는 받아쓰기 동작입니다.".into()),
            };
            let preview = if code == 1 {
                let settings = preview_settings.unwrap_or(dictation_get_settings(app.clone())?);
                Some(
                    std::ffi::CString::new(overlay_configuration(&app, settings)?.to_string())
                        .map_err(|_| "설정을 준비하지 못했습니다.")?,
                )
            } else {
                None
            };
            let (tx, rx) = tokio::sync::oneshot::channel();
            app.run_on_main_thread(move || {
                unsafe {
                    if let Some(preview) = preview {
                        prism_dictation_preview(preview.as_ptr());
                    } else {
                        prism_dictation_action(code);
                    }
                };
                let _ = tx.send(());
            })
            .map_err(|_| "받아쓰기에 접근하지 못했습니다.")?;
            rx.await.map_err(|_| "받아쓰기에 접근하지 못했습니다.")?;
        }
        STATUS
            .get_or_init(|| Mutex::new(json!({})))
            .lock()
            .map(|value| value.clone())
            .map_err(|_| "받아쓰기 상태를 읽지 못했습니다.".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, action);
        Err("받아쓰기는 현재 macOS에서 지원합니다.".into())
    }
}
#[tauri::command]
pub async fn dictation_pick_file(kind: String) -> Result<Option<String>, String> {
    if kind != "model" && kind != "executable" {
        return Err("올바른 파일 종류를 선택하세요.".into());
    }
    let picked = rfd::AsyncFileDialog::new()
        .set_title(if kind == "model" {
            "Whisper model (.bin)"
        } else {
            "whisper.cpp executable"
        })
        .pick_file()
        .await;
    Ok(picked.map(|file| file.path().to_string_lossy().into_owned()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn both_enhancements_survive_roundtrip_without_changing_profiles() {
        let mut settings = super::DictationSettings::default();
        settings.enhancement_mode = Some("both".into());
        settings.cleanup_instruction = "Keep names".into();
        settings.prompt_instruction = "Keep constraints".into();
        settings.upgrade();
        assert!(settings.refine_text);
        assert!(settings.validate().is_ok());
        let mut restored: super::DictationSettings = serde_json::from_value(serde_json::to_value(&settings).unwrap()).unwrap();
        restored.upgrade();
        assert_eq!(restored.enhancement_mode.as_deref(), Some("both"));
        assert_eq!(restored.cleanup_instruction, "Keep names");
        assert_eq!(restored.prompt_instruction, "Keep constraints");
        restored.enhancement_mode = Some("prompt".into());
        restored.upgrade();
        assert!(!restored.refine_text);
    }
    #[test]
    fn migrates_shared_model_once_and_retains_independent_profiles_when_off() {
        let mut value = serde_json::to_value(super::DictationSettings::default()).unwrap();
        value.as_object_mut().unwrap().remove("enhancementMode");
        value["refineText"] = serde_json::json!(true);
        value["processingModel"] = serde_json::json!({"provider":"vercel","model":"legacy/model"});
        let mut settings: super::DictationSettings = serde_json::from_value(value).unwrap();
        settings.upgrade();
        assert_eq!(settings.enhancement_mode.as_deref(), Some("cleanup"));
        assert_eq!(settings.cleanup_model.as_ref().unwrap().model, "legacy/model");
        assert_eq!(settings.prompt_model.as_ref().unwrap().model, "legacy/model");
        settings.enhancement_mode = Some("off".into());
        settings.prompt_model.as_mut().unwrap().model = "new/model".into();
        settings.prompt_instruction = "Keep short paragraphs".into();
        settings.upgrade();
        assert!(!settings.refine_text);
        assert_eq!(settings.prompt_model.as_ref().unwrap().model, "new/model");
        assert_eq!(settings.prompt_instruction, "Keep short paragraphs");
        assert!(settings.validate().is_ok());
    }
    #[test]
    fn older_settings_keep_refinement_off_and_processing_selection_is_validated() {
        let mut value = serde_json::to_value(super::DictationSettings::default()).unwrap();
        value.as_object_mut().unwrap().remove("refineText");
        value.as_object_mut().unwrap().remove("processingModel");
        let settings: super::DictationSettings = serde_json::from_value(value.clone()).unwrap();
        assert!(!settings.refine_text);
        assert!(settings.processing_model.is_none());
        value["processingModel"] = serde_json::json!({"provider":"vercel","model":"fixture/model","modelName":"Fixture"});
        let settings: super::DictationSettings = serde_json::from_value(value.clone()).unwrap();
        assert!(settings.validate().is_ok());
        value["processingModel"]["model"] = serde_json::json!("bad model");
        let settings: super::DictationSettings = serde_json::from_value(value).unwrap();
        assert!(settings.validate().is_err());
    }

    use super::*;
    fn remote(provider: &str, base: &str) -> DictationSettings {
        DictationSettings {
            provider: provider.into(),
            model: "whisper-1".into(),
            base_url: base.into(),
            ..DictationSettings::default()
        }
    }
    #[test]
    fn delivery_and_recording_shortcuts_validate_and_migrate() {
        let settings = DictationSettings::default();
        let mut value = serde_json::to_value(&settings).unwrap();
        for key in [
            "defaultDelivery",
            "recordingCancelShortcut",
            "recordingCopyShortcut",
            "recordingPasteShortcut",
            "recordingPasteAndEnterShortcut",
        ] {
            value.as_object_mut().unwrap().remove(key);
        }
        let migrated: DictationSettings = serde_json::from_value(value).unwrap();
        assert_eq!(migrated.default_delivery, "paste");
        assert_eq!(migrated.recording_copy_shortcut.mode, "disabled");
        assert!(migrated.validate().is_ok());
        let mut changed = migrated;
        changed.default_delivery = "copy".into();
        assert!(changed.validate().is_ok());
        changed.recording_paste_shortcut = changed.recording_cancel_shortcut.clone();
        assert!(changed.validate().unwrap_err().contains("다른 단축키"));
        changed.recording_paste_shortcut.mode = "disabled".into();
        assert!(changed.validate().is_ok());
        changed.recording_copy_shortcut.mode = "custom".into();
        assert!(changed.validate().is_err());
    }
    #[test]
    fn provider_keys_cannot_be_sent_to_custom_hosts() {
        assert!(remote("openai", "https://attacker.example/v1")
            .validate()
            .is_err());
        assert!(remote("vercel", "https://ai-gateway.vercel.sh/v4/ai")
            .validate()
            .is_ok());
        assert!(remote("custom", "https://example.com/v1")
            .validate()
            .is_ok());
        for base in [
            "http://example.com",
            "https://user:secret@example.com",
            "https://example.com?key=secret",
            "file:///tmp/audio",
        ] {
            assert!(remote("custom", base).validate().is_err());
        }
        assert!(remote("custom", "http://127.0.0.1:9876/v1")
            .validate()
            .is_ok());
    }
    #[test]
    fn settings_roundtrip_rejects_keys_and_realtime_models() {
        let saved = remote("openai", "https://api.openai.com/v1");
        let mut value = serde_json::to_value(&saved).unwrap();
        assert!(value.get("apiKey").is_none());
        assert_eq!(
            serde_json::from_value::<DictationSettings>(value.clone())
                .unwrap()
                .base_url,
            saved.base_url
        );
        value["apiKey"] = json!("secret");
        assert!(serde_json::from_value::<DictationSettings>(value).is_err());
        let mut realtime = saved;
        realtime.model = "gpt-realtime-whisper".into();
        assert!(realtime.validate().is_err());
        assert!(DictationSettings::default().preflight().is_err());
    }
}
