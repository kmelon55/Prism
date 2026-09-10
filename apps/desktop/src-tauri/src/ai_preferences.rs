use crate::ai::Provider;
use serde::{Deserialize, Serialize};
use std::{fs, path::Path, sync::Mutex};
use tauri::{Manager, State};

#[derive(Default)]
pub struct AiPreferences(Mutex<()>);

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiSelection {
    provider: Provider,
    model: String,
    model_name: Option<String>,
}

impl AiSelection {
    fn validate(&self) -> Result<(), String> {
        if self.model.is_empty()
            || self.model.len() > 200
            || !self.model.bytes().all(|b| b.is_ascii_graphic())
            || self
                .model_name
                .as_ref()
                .is_some_and(|name| name.len() > 720 || name.chars().any(char::is_control))
        {
            return Err("올바른 모델을 선택하세요.".into());
        }
        Ok(())
    }
}

fn read(path: &Path) -> Result<Option<AiSelection>, String> {
    match fs::metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(meta) if meta.len() <= 4096 => (),
        _ => return Err("저장된 AI 설정을 읽지 못했습니다.".into()),
    }
    let value: AiSelection =
        serde_json::from_slice(&fs::read(path).map_err(|_| "AI 설정을 읽지 못했습니다.")?)
            .map_err(|_| "AI 설정 형식이 올바르지 않습니다.")?;
    value.validate()?;
    Ok(Some(value))
}

fn write(path: &Path, selection: &AiSelection) -> Result<AiSelection, String> {
    selection.validate()?;
    let bytes = serde_json::to_vec(selection).map_err(|_| "모델 선택을 저장하지 못했습니다.")?;
    fs::create_dir_all(path.parent().ok_or("AI 설정 경로가 올바르지 않습니다.")?)
        .map_err(|_| "AI 설정 폴더를 만들지 못했습니다.")?;
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, bytes)
        .and_then(|_| fs::rename(&temporary, path))
        .map_err(|_| "모델 선택을 저장하지 못했습니다.")?;
    read(path)?.ok_or_else(|| "저장된 모델 선택을 확인하지 못했습니다.".into())
}

#[tauri::command]
pub fn ai_get_selection(
    app: tauri::AppHandle,
    state: State<'_, AiPreferences>,
    legacy: Option<AiSelection>,
) -> Result<Option<AiSelection>, String> {
    let _guard = state.0.lock().map_err(|_| "AI 설정을 읽지 못했습니다.")?;
    let path = app
        .path()
        .app_data_dir()
        .map_err(|_| "AI 설정 경로를 찾지 못했습니다.")?
        .join("ai-selection-v1.json");
    if let Some(saved) = read(&path)? {
        return Ok(Some(saved));
    }
    // Migration runs under the same lock as writes, so another window cannot overwrite a newer selection.
    legacy.map(|selection| write(&path, &selection)).transpose()
}

#[tauri::command]
pub fn ai_set_selection(
    app: tauri::AppHandle,
    state: State<'_, AiPreferences>,
    selection: AiSelection,
) -> Result<AiSelection, String> {
    let _guard = state
        .0
        .lock()
        .map_err(|_| "모델 선택을 저장하지 못했습니다.")?;
    let path = app
        .path()
        .app_data_dir()
        .map_err(|_| "AI 설정 경로를 찾지 못했습니다.")?
        .join("ai-selection-v1.json");
    write(&path, &selection)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_survives_reopen_and_rejects_invalid_replacement() {
        let dir = std::env::temp_dir().join(format!("prism-ai-preferences-{}", std::process::id()));
        let path = dir.join("ai-selection-v1.json");
        let selection = AiSelection {
            provider: Provider::Vercel,
            model: "creator/model".into(),
            model_name: Some("My model".into()),
        };
        write(&path, &selection).unwrap();
        assert_eq!(
            read(&path).unwrap().unwrap().model_name.as_deref(),
            Some("My model")
        );
        assert!(write(
            &path,
            &AiSelection {
                model: "bad model".into(),
                ..selection
            }
        )
        .is_err());
        assert_eq!(read(&path).unwrap().unwrap().model, "creator/model");
        fs::remove_dir_all(dir).unwrap();
    }
}
