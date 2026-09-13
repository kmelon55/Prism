use crate::ai::Provider;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    path::Path,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::{Manager, State};

#[derive(Default)]
pub struct AiHistory(Mutex<()>);
#[derive(Clone, Deserialize, Serialize)]
pub struct Turn {
    #[serde(default, rename = "modelName", skip_serializing_if = "Option::is_none")]
    model_name: Option<String>,
    role: String,
    content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    image: Option<crate::ai_capture::ChatImage>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    id: String,
    provider: Provider,
    model: String,
    model_name: Option<String>,
    title: String,
    messages: Vec<Turn>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    compaction: Option<crate::ai_context::Compaction>,
    draft: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    draft_image: Option<crate::ai_capture::ChatImage>,
    updated_at: u64,
    #[serde(default)]
    pinned: bool,
}
fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
}
fn validate(session: &Session) -> Result<(), String> {
    if !valid_id(&session.id)
        || session.title.len() > 300
        || session.model.len() > 200
        || !session.model.bytes().all(|b| b.is_ascii_graphic())
        || session
            .model_name
            .as_ref()
            .is_some_and(|name| name.len() > 720)
        || session.draft.len() > 128_000
        || session.messages.len() % 2 != 0
        || session.messages.iter().enumerate().any(|(i, m)| {
            m.model_name.as_ref().is_some_and(|name| name.len() > 720)
                || m.role != if i % 2 == 0 { "user" } else { "assistant" }
                || m.content.is_empty()
                || m.content.len() > 1_048_576
        })
        || session
            .messages
            .iter()
            .map(|m| m.content.len())
            .sum::<usize>()
            > crate::ai_context::MAX_ARCHIVE_BYTES
    {
        return Err("대화 기록이 너무 크거나 올바르지 않습니다.".into());
    }
    if let Some(compaction) = &session.compaction { compaction.validate(session.messages.len())?; }
    let images: Vec<_> = session.messages.iter().filter_map(|message| message.image.as_ref()).chain(session.draft_image.as_ref()).collect();
    if session.messages.iter().any(|message| message.role != "user" && message.image.is_some()) {
        return Err("Conversation images must belong to user messages.".into());
    }
    for image in images { crate::ai_capture::validate_image(image)?; }
    Ok(())
}
fn database(path: &Path) -> Result<Connection, String> {
    std::fs::create_dir_all(path.parent().ok_or("대화 기록 경로를 찾지 못했습니다.")?)
        .map_err(|_| "대화 기록 폴더를 만들지 못했습니다.")?;
    let db = Connection::open(path).map_err(|_| "대화 기록을 열지 못했습니다.")?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, content TEXT NOT NULL);")
        .map_err(|_| "대화 기록을 준비하지 못했습니다.")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "대화 기록 접근 권한을 설정하지 못했습니다.")?;
    }
    Ok(db)
}
fn save(db: &Connection, mut session: Session) -> Result<Session, String> {
    validate(&session)?;
    let count: u64 = db
        .query_row(
            "SELECT COUNT(*) FROM conversations WHERE id != ?1",
            [&session.id],
            |row| row.get(0),
        )
        .map_err(|_| "대화 기록을 확인하지 못했습니다.")?;
    if count >= 100 {
        return Err("대화는 최대 100개까지 보관합니다. 불필요한 대화를 삭제하세요.".into());
    }
    session.updated_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let content = serde_json::to_string(&session).map_err(|_| "대화를 저장하지 못했습니다.")?;
    let other_bytes: u64 = db.query_row("SELECT COALESCE(SUM(length(CAST(content AS BLOB))),0) FROM conversations WHERE id != ?1", [&session.id], |row| row.get(0)).map_err(|_| "대화 기록 용량을 확인하지 못했습니다.")?;
    if other_bytes + content.len() as u64 > 32 * 1024 * 1024 {
        return Err("대화 기록 저장 공간이 가득 찼습니다. 불필요한 대화를 삭제하세요.".into());
    }
    db.execute("INSERT INTO conversations (id,updated_at,content) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, content=excluded.content", params![session.id, session.updated_at, content])
        .map_err(|_| "대화를 저장하지 못했습니다. 디스크 공간을 확인하세요.")?;
    Ok(session)
}
#[tauri::command]
pub fn ai_load_history(
    app: tauri::AppHandle,
    state: State<'_, AiHistory>,
) -> Result<Vec<Session>, String> {
    let _guard = state.0.lock().map_err(|_| "대화 기록을 읽지 못했습니다.")?;
    let path = app
        .path()
        .app_data_dir()
        .map_err(|_| "대화 기록 경로를 찾지 못했습니다.")?
        .join("ai-conversations.sqlite3");
    let db = database(&path)?;
    let mut query = db
        .prepare("SELECT content FROM conversations ORDER BY updated_at DESC LIMIT 100")
        .map_err(|_| "대화 기록을 읽지 못했습니다.")?;
    let rows = query
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|_| "대화 기록을 읽지 못했습니다.")?;
    rows.map(|row| {
        let text = row.map_err(|_| "대화 기록을 읽지 못했습니다.")?;
        if text.len() > crate::ai_context::MAX_ARCHIVE_BYTES {
            return Err("대화 기록이 너무 큽니다.".into());
        }
        let session =
            serde_json::from_str(&text).map_err(|_| "대화 기록 형식이 올바르지 않습니다.")?;
        validate(&session)?;
        Ok(session)
    })
    .collect()
}
#[tauri::command]
pub fn ai_save_session(
    app: tauri::AppHandle,
    state: State<'_, AiHistory>,
    session: Session,
) -> Result<Session, String> {
    let _guard = state.0.lock().map_err(|_| "대화를 저장하지 못했습니다.")?;
    let path = app
        .path()
        .app_data_dir()
        .map_err(|_| "대화 기록 경로를 찾지 못했습니다.")?
        .join("ai-conversations.sqlite3");
    save(&database(&path)?, session)
}
#[tauri::command]
pub fn ai_delete_session(
    app: tauri::AppHandle,
    state: State<'_, AiHistory>,
    session_id: String,
) -> Result<(), String> {
    if !valid_id(&session_id) {
        return Err("올바르지 않은 대화입니다.".into());
    }
    let _guard = state.0.lock().map_err(|_| "대화를 삭제하지 못했습니다.")?;
    let path = app
        .path()
        .app_data_dir()
        .map_err(|_| "대화 기록 경로를 찾지 못했습니다.")?
        .join("ai-conversations.sqlite3");
    database(&path)?
        .execute("DELETE FROM conversations WHERE id=?1", [session_id])
        .map_err(|_| "대화를 삭제하지 못했습니다.")?;
    Ok(())
}
#[tauri::command]
pub async fn ai_export_session(session: Session, locale: Option<String>) -> Result<bool, String> {
    validate(&session)?;
    let english = locale.as_deref() == Some("en");
    let title = session
        .title
        .chars()
        .map(|c| {
            if c.is_control() || "/\\:*?\"<>|".contains(c) {
                '_'
            } else {
                c
            }
        })
        .take(70)
        .collect::<String>();
    let Some(file) = rfd::AsyncFileDialog::new()
        .set_file_name(format!("{title}.md"))
        .add_filter("Markdown", &["md"])
        .save_file()
        .await
    else {
        return Ok(false);
    };
    let mut text = format!("# {}\n\n", session.title.replace(['\r', '\n'], " "));
    for message in session.messages {
        if let Some(image) = &message.image { text.push_str(&format!("![Screen capture]({})\n\n", image.data_url)); }
        text.push_str(&format!(
            "## {}\n\n{}\n\n",
            if message.role == "user" {
                if english { "You" } else { "나" }.to_owned()
            } else {
                message.model_name.unwrap_or_else(|| session.model.clone())
            },
            message.content
        ));
    }
    if let Some(image) = &session.draft_image { text.push_str(&format!("![Draft screen capture]({})\n\n", image.data_url)); }
    if !session.draft.is_empty() {
        text.push_str(&format!(
            "## {}\n\n{}\n",
            if english { "Draft" } else { "초안" },
            session.draft
        ));
    }
    let path = file.path().to_owned();
    tauri::async_runtime::spawn_blocking(move || {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options
            .open(path)
            .and_then(|mut f| {
                f.write_all(text.as_bytes())?;
                f.sync_all()
            })
            .map_err(|_| "대화를 내보내지 못했습니다.".to_string())
    })
    .await
    .map_err(|_| "내보내기가 중단되었습니다.".to_string())??;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persists_long_original_history_with_a_separate_summary_and_validates_boundaries() {
        let messages: Vec<_> = (0..120).map(|i| serde_json::json!({"role": if i % 2 == 0 {"user"} else {"assistant"}, "content": format!("Original message {i}")})).collect();
        let mut value = serde_json::json!({"id":"12345678-1234-1234-1234-123456789012","provider":"openai","model":"fixture","title":"Long conversation","messages":messages,"draft":"Continue","updatedAt":0,"compaction":{"summary":"Important decisions","through":100}});
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE conversations (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, content TEXT NOT NULL);").unwrap();
        save(&db, serde_json::from_value(value.clone()).unwrap()).unwrap();
        let stored: String = db.query_row("SELECT content FROM conversations", [], |r| r.get(0)).unwrap();
        let loaded: Session = serde_json::from_str(&stored).unwrap();
        assert_eq!(loaded.messages.len(), 120);
        assert_eq!(loaded.messages[0].content, "Original message 0");
        assert_eq!(loaded.compaction.unwrap().through, 100);
        for through in [1, 121, 122] {
            value["compaction"]["through"] = serde_json::json!(through);
            assert!(save(&db, serde_json::from_value(value.clone()).unwrap()).is_err());
        }
        let preserved: String = db.query_row("SELECT content FROM conversations", [], |r| r.get(0)).unwrap();
        assert_eq!(stored, preserved);
    }
    #[test]
    fn preserves_capture_drafts_turns_and_old_text_sessions() {
        let mut value = serde_json::json!({"id":"12345678-1234-1234-1234-123456789012","provider":"compatible","model":"vision","title":"Capture","messages":[],"draft":"","updatedAt":0});
        let legacy: Session = serde_json::from_value(value.clone()).unwrap();
        validate(&legacy).unwrap(); assert!(legacy.draft_image.is_none());
        let image = crate::ai_capture::tests::fixture();
        value["draftImage"] = serde_json::to_value(&image).unwrap();
        let draft: Session = serde_json::from_value(value.clone()).unwrap();
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE conversations (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, content TEXT NOT NULL);").unwrap();
        save(&db, draft).unwrap();
        let stored: String = db.query_row("SELECT content FROM conversations", [], |r| r.get(0)).unwrap();
        assert_eq!(serde_json::from_str::<Session>(&stored).unwrap().draft_image.unwrap().data_url, image.data_url);
        value["draftImage"] = serde_json::Value::Null;
        value["messages"] = serde_json::json!([{"role":"user","content":"Explain","image":image},{"role":"assistant","content":"Answer"}]);
        validate(&serde_json::from_value(value.clone()).unwrap()).unwrap();
        value["messages"][1]["image"] = value["messages"][0]["image"].clone();
        assert!(validate(&serde_json::from_value(value).unwrap()).is_err());
    }
    #[test]
    fn persists_complete_turns_and_drafts_without_overwriting_other_sessions() {
        let path =
            std::env::temp_dir().join(format!("prism-history-test-{}.sqlite3", std::process::id()));
        let db = database(&path).unwrap();
        let session = Session {
            id: "12345678-1234-1234-1234-123456789012".into(),
            provider: Provider::Vercel,
            model: "maker/chat".into(),
            model_name: None,
            title: "Question".into(),
            draft: "Retry me".into(),
            draft_image: None,
            messages: vec![],
            compaction: None,
            updated_at: 0,
            pinned: false,
        };
        save(&db, session.clone()).unwrap();
        save(
            &db,
            Session {
                id: "12345678-1234-1234-1234-123456789013".into(),
                ..session.clone()
            },
        )
        .unwrap();
        assert!(save(
            &db,
            Session {
                messages: vec![Turn {
                    image: None,
                    model_name: None,
                    role: "assistant".into(),
                    content: "bad".into()
                }],
                ..session.clone()
            }
        )
        .is_err());
        drop(db);
        let db = database(&path).unwrap();
        let text: String = db
            .query_row(
                "SELECT content FROM conversations WHERE id=?1",
                [session.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Session>(&text).unwrap().draft,
            "Retry me"
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM conversations", [], |row| row
                .get::<_, usize>(0))
                .unwrap(),
            2
        );
        drop(db);
        std::fs::remove_file(path).unwrap();
    }
}
