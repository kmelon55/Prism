use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    hash::{BuildHasher, Hash, Hasher},
    io::Read,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
};
use tauri::{Emitter, Manager, State};
use unicode_normalization::UnicodeNormalization;
fn search_key(value: &str) -> String {
    value.nfkc().collect::<String>().to_lowercase()
}

#[path = "library_backup.rs"]
pub mod backup;
mod file_index;

const MAX_FILES: usize = 100_000;
#[derive(Default)]
pub struct Library {
    lock: Mutex<()>,
    generation: AtomicU64,
    index: Mutex<file_index::IndexState>,
    issued: Mutex<VecDeque<(String, String)>>,
    token_hash: std::collections::hash_map::RandomState,
    token_counter: AtomicU64,
    prepared: Mutex<HashMap<String, PreparedRun>>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyword: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Root {
    pub id: String,
    pub path: String,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Favorite {
    pub id: String,
    pub title: String,
}
#[derive(Serialize)]
pub struct LibraryData {
    entries: Vec<Entry>,
    roots: Vec<Root>,
    favorites: Vec<Favorite>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileHit {
    id: String,
    name: String,
    path: String,
    is_directory: bool,
}
#[derive(Serialize)]
pub struct FileResults {
    items: Vec<FileHit>,
    total: usize,
    limited: bool,
    indexing: bool,
    error: Option<String>,
}
fn db(app: &tauri::AppHandle) -> Result<Connection, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|_| "보관함 경로를 찾지 못했습니다.")?;
    std::fs::create_dir_all(&dir).map_err(|_| "보관함 폴더를 만들지 못했습니다.")?;
    let path = dir.join("library-v1.sqlite3");
    let db = Connection::open(&path).map_err(|_| "보관함을 열지 못했습니다.")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "보관함 접근 권한을 설정하지 못했습니다.")?;
    }
    schema(&db)?;
    Ok(db)
}
fn schema(db: &Connection) -> Result<(), String> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY,kind TEXT NOT NULL,title TEXT NOT NULL,value TEXT NOT NULL,keyword TEXT); CREATE TABLE IF NOT EXISTS roots(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE); CREATE TABLE IF NOT EXISTS favorites(id TEXT PRIMARY KEY,title TEXT NOT NULL,position INTEGER NOT NULL);").map_err(|_| "보관함을 준비하지 못했습니다.".to_string())?;
    let has_keyword: bool = db
        .query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('entries') WHERE name='keyword'",
            [],
            |row| row.get(0),
        )
        .map_err(|_| "보관함 형식을 확인하지 못했습니다.".to_string())?;
    if !has_keyword {
        db.execute("ALTER TABLE entries ADD COLUMN keyword TEXT", [])
            .map_err(|_| "스니펫 형식을 갱신하지 못했습니다.".to_string())?;
    }
    db.execute("CREATE UNIQUE INDEX IF NOT EXISTS entries_keyword_unique ON entries(keyword) WHERE keyword IS NOT NULL AND keyword != ''", [])
        .map_err(|_| "스니펫 단축어를 준비하지 못했습니다.".to_string())?;
    Ok(())
}

fn normalized_keyword(entry: &Entry) -> Option<&str> {
    entry
        .keyword
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 512 && !id.chars().any(char::is_control)
}
fn validate_entry(entry: &Entry) -> Result<(), String> {
    if !valid_id(&entry.id)
        || entry.title.trim().is_empty()
        || entry.title.len() > 300
        || entry.value.is_empty()
        || entry.value.len() > 128 * 1024
    {
        return Err("이름과 내용을 확인하세요. 내용은 최대 128 KB입니다.".into());
    }
    if let Some(keyword) = normalized_keyword(entry) {
        if entry.kind != "snippet"
            || !(2..=48).contains(&keyword.len())
            || !matches!(keyword.as_bytes()[0], b';' | b'!' | b'/' | b':')
            || !keyword
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_-;!/:".contains(&byte))
        {
            return Err(
                "단축어는 ; ! / : 중 하나로 시작하는 2~48자의 영문·숫자·기호로 입력하세요.".into(),
            );
        }
    }
    match entry.kind.as_str() {
        "snippet" => {}
        "link" => {
            validate_link_template(&entry.value)?;
        }
        "path" => {
            if !Path::new(&entry.value).is_absolute() || entry.value.chars().any(char::is_control) {
                return Err("절대 경로를 선택하세요.".into());
            }
        }
        _ => return Err("지원하지 않는 보관함 항목입니다.".into()),
    }
    Ok(())
}
fn save(db: &Connection, entry: &Entry) -> Result<(), String> {
    validate_entry(entry)?;
    let keyword = normalized_keyword(entry);
    if let Some(keyword) = keyword {
        let exists: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM entries WHERE keyword=?1 AND id!=?2)",
                params![keyword, entry.id],
                |row| row.get(0),
            )
            .map_err(|_| "스니펫 단축어를 확인하지 못했습니다.".to_string())?;
        if exists {
            return Err("이미 사용 중인 스니펫 단축어입니다.".into());
        }
    }
    let (count, bytes):(usize,usize)=db.query_row("SELECT COUNT(*),COALESCE(SUM(length(CAST(value AS BLOB))),0) FROM entries WHERE id!=?1",[&entry.id],|r|Ok((r.get(0)?,r.get(1)?))).map_err(|_|"보관함 용량을 확인하지 못했습니다.")?;
    if count >= 1000 || bytes + entry.value.len() > 16 * 1024 * 1024 {
        return Err("보관함이 가득 찼습니다. 불필요한 항목을 삭제하세요.".into());
    }
    db.execute("INSERT INTO entries(id,kind,title,value,keyword) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,title=excluded.title,value=excluded.value,keyword=excluded.keyword",params![entry.id,entry.kind,entry.title.trim(),entry.value,keyword]).map_err(|_|"항목을 저장하지 못했습니다.")?;
    Ok(())
}
fn read(db: &Connection) -> Result<LibraryData, String> {
    let entries = db
        .prepare("SELECT id,kind,title,value,keyword FROM entries ORDER BY title COLLATE NOCASE")
        .map_err(|e| e.to_string())?
        .query_map([], |r| {
            Ok(Entry {
                id: r.get(0)?,
                kind: r.get(1)?,
                title: r.get(2)?,
                value: r.get(3)?,
                keyword: r.get(4)?,
            })
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "항목을 읽지 못했습니다.")?;
    let roots = db
        .prepare("SELECT id,path FROM roots ORDER BY path")
        .map_err(|e| e.to_string())?
        .query_map([], |r| {
            Ok(Root {
                id: r.get(0)?,
                path: r.get(1)?,
            })
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "검색 폴더를 읽지 못했습니다.")?;
    let favorites = db
        .prepare("SELECT id,title FROM favorites ORDER BY position")
        .map_err(|e| e.to_string())?
        .query_map([], |r| {
            Ok(Favorite {
                id: r.get(0)?,
                title: r.get(1)?,
            })
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| "즐겨찾기를 읽지 못했습니다.")?;
    Ok(LibraryData {
        entries,
        roots,
        favorites,
    })
}
fn changed(app: &tauri::AppHandle) {
    let _ = app.emit("prism:library-changed", ());
}
pub fn snippet_entries(app: &tauri::AppHandle) -> Result<Vec<Entry>, String> {
    let state = app.state::<Library>();
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    Ok(read(&db(app)?)?
        .entries
        .into_iter()
        .filter(|entry| entry.kind == "snippet")
        .collect())
}
#[tauri::command]
pub fn library_load(
    app: tauri::AppHandle,
    state: State<'_, Library>,
) -> Result<LibraryData, String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    read(&db(&app)?)
}
#[tauri::command]
pub fn library_save_entry(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    entry: Entry,
) -> Result<(), String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    save(&db(&app)?, &entry)?;
    drop(_guard);
    crate::snippet_expansion::refresh(&app);
    changed(&app);
    Ok(())
}
#[tauri::command]
pub fn library_delete_entry(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    id: String,
) -> Result<(), String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    let mut db = db(&app)?;
    let tx = db
        .transaction()
        .map_err(|_| "항목을 삭제하지 못했습니다.")?;
    tx.execute("DELETE FROM entries WHERE id=?1", [&id])
        .map_err(|_| "항목을 삭제하지 못했습니다.")?;
    tx.execute(
        "DELETE FROM favorites WHERE id=?1",
        [format!("library:{id}")],
    )
    .map_err(|_| "즐겨찾기를 갱신하지 못했습니다.")?;
    tx.commit().map_err(|_| "항목을 삭제하지 못했습니다.")?;
    drop(_guard);
    crate::snippet_expansion::refresh(&app);
    changed(&app);
    Ok(())
}
#[tauri::command]
pub fn library_set_favorite(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    favorite: Favorite,
    enabled: bool,
) -> Result<(), String> {
    if !valid_id(&favorite.id) || favorite.title.len() > 500 {
        return Err("올바르지 않은 즐겨찾기입니다.".into());
    }
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    let db = db(&app)?;
    if enabled {
        let count: i64 = db
            .query_row("SELECT COUNT(*) FROM favorites", [], |r| r.get(0))
            .map_err(|_| "즐겨찾기를 읽지 못했습니다.")?;
        if count >= 50 {
            return Err("즐겨찾기는 최대 50개입니다.".into());
        }
        db.execute("INSERT INTO favorites VALUES(?1,?2,(SELECT COALESCE(MAX(position),0)+1 FROM favorites)) ON CONFLICT(id) DO UPDATE SET title=excluded.title",params![favorite.id,favorite.title]).map_err(|_|"즐겨찾기를 저장하지 못했습니다.")?;
    } else {
        db.execute("DELETE FROM favorites WHERE id=?1", [favorite.id])
            .map_err(|_| "즐겨찾기를 삭제하지 못했습니다.")?;
    }
    changed(&app);
    Ok(())
}
#[tauri::command]
pub fn library_reorder_favorites(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    ids: Vec<String>,
) -> Result<(), String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    let mut db = db(&app)?;
    let current = read(&db)?.favorites;
    if ids.len() != current.len()
        || ids.iter().collect::<HashSet<_>>().len() != ids.len()
        || current.iter().any(|f| !ids.contains(&f.id))
    {
        return Err("즐겨찾기가 변경되었습니다. 다시 시도하세요.".into());
    }
    let tx = db
        .transaction()
        .map_err(|_| "순서를 저장하지 못했습니다.")?;
    for (i, id) in ids.iter().enumerate() {
        tx.execute(
            "UPDATE favorites SET position=?1 WHERE id=?2",
            params![i, id],
        )
        .map_err(|_| "순서를 저장하지 못했습니다.")?;
    }
    tx.commit().map_err(|_| "순서를 저장하지 못했습니다.")?;
    changed(&app);
    Ok(())
}
#[tauri::command]
pub async fn library_choose_path(folder: bool) -> Result<Option<String>, String> {
    let dialog = rfd::AsyncFileDialog::new();
    let chosen = if folder {
        dialog.pick_folder().await
    } else {
        dialog.pick_file().await
    };
    Ok(chosen.map(|f| f.path().to_string_lossy().into_owned()))
}
#[tauri::command]
pub async fn library_add_root(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    locale: Option<String>,
) -> Result<(), String> {
    let Some(folder) = rfd::AsyncFileDialog::new()
        .set_title(if locale.as_deref() == Some("en") {
            "File search folders"
        } else {
            "파일 검색 폴더"
        })
        .pick_folder()
        .await
    else {
        return Ok(());
    };
    let path = folder
        .path()
        .canonicalize()
        .map_err(|_| "폴더에 접근하지 못했습니다.")?;
    {
        let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
        let db = db(&app)?;
        if read(&db)?.roots.len() >= 12 {
            return Err("검색 폴더는 최대 12개입니다.".into());
        }
        db.execute(
            "INSERT OR IGNORE INTO roots VALUES(lower(hex(randomblob(16))),?1)",
            [path.to_string_lossy().as_ref()],
        )
        .map_err(|_| "검색 폴더를 저장하지 못했습니다.")?;
        invalidate_file_index(&app, &state);
    }
    changed(&app);
    Ok(())
}
#[tauri::command]
pub fn library_remove_root(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    id: String,
) -> Result<(), String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    db(&app)?
        .execute("DELETE FROM roots WHERE id=?1", [id])
        .map_err(|_| "검색 폴더를 제거하지 못했습니다.")?;
    invalidate_file_index(&app, &state);
    changed(&app);
    Ok(())
}
#[cfg(test)]
fn scan(roots: &[Root], cancel: impl Fn() -> bool) -> (Vec<FileHit>, bool) {
    let snapshot = file_index::refresh(roots, 0, None, cancel);
    (snapshot.page("", "all", 0, MAX_FILES).0, snapshot.limited)
}

fn index_cache_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_cache_dir()
        .map(|dir| dir.join("file-index-v1.json"))
        .map_err(|_| "파일 목록 캐시 경로를 찾지 못했습니다.".into())
}
// Called while the library mutation lock is held, also fencing disk publication.
fn invalidate_file_index(app: &tauri::AppHandle, state: &Library) {
    state.generation.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut index) = state.index.lock() {
        index.snapshot = None;
        index.watcher = None;
        index.pending.clear();
        index.force_pending = true;
        index.error = None;
        index.watcher_error = None;
    }
    if let Ok(path) = index_cache_path(app) {
        let _ = std::fs::remove_file(path);
    }
}

// At most one disk worker; queries use published snapshots without scanning.
fn ensure_index(app: tauri::AppHandle, force: bool) -> Result<(), String> {
    let state = app.state::<Library>();
    let generation = state.generation.load(Ordering::SeqCst);
    let (previous, paths, force) = {
        let mut index = state
            .index
            .lock()
            .map_err(|_| "파일 목록을 읽지 못했습니다.")?;
        index.force_pending |= force;
        if index.refreshing {
            return Ok(());
        }
        let force = index.force_pending;
        if !force && index.pending.is_empty() {
            if index.current(generation).is_some() {
                return Ok(());
            }
            if index.error.is_some()
                && index
                    .attempted
                    .is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(2))
            {
                return Ok(());
            }
        }
        index.force_pending = false;
        index.refreshing = true;
        index.attempted = Some(std::time::Instant::now());
        (
            index.current(generation).cloned(),
            std::mem::take(&mut index.pending),
            force,
        )
    };
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Library>();
        let result = (|| -> Result<_, String> {
            let roots = {
                let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
                let mut roots = read(&db(&app)?)?.roots;
                roots.insert(0, spotlight_root(&app)?);
                roots
            };
            let cancelled = || state.generation.load(Ordering::SeqCst) != generation;
            if cancelled() {
                return Err("검색 폴더가 변경되었습니다.".into());
            }
            let needs_watcher = force
                || roots.iter().any(|r| paths.contains(Path::new(&r.path)))
                || state
                    .index
                    .lock()
                    .map_err(|_| "파일 목록을 읽지 못했습니다.")?
                    .watcher
                    .as_ref()
                    .is_none_or(|(version, _)| *version != generation);
            if needs_watcher {
                let event_app = app.clone();
                let watcher = file_index::EventWatcher::start(roots.clone(), move |paths| {
                    let state = event_app.state::<Library>();
                    if state.generation.load(Ordering::SeqCst) != generation {
                        return;
                    }
                    if let Ok(mut index) = state.index.lock() {
                        // Coalesce between batches too, while a scan is in flight.
                        for path in paths {
                            if index.pending.len() >= 512 {
                                index.pending.clear();
                                index.force_pending = true;
                                break;
                            }
                            index.pending.insert(path);
                        }
                    }
                    let _ = ensure_index(event_app.clone(), false);
                });
                let mut index = state
                    .index
                    .lock()
                    .map_err(|_| "파일 목록을 읽지 못했습니다.")?;
                if !cancelled() {
                    match watcher {
                        Ok((watcher, warning)) => {
                            index.watcher = Some((generation, watcher));
                            index.watcher_error = warning;
                        }
                        Err(error) => {
                            index.watcher_error = Some(error);
                        }
                    }
                }
            }
            let cache_path = index_cache_path(&app).ok();
            let restored = if previous.is_none() && !force {
                cache_path
                    .as_ref()
                    .and_then(|path| file_index::load_cache(path, &roots, generation))
                    .map(std::sync::Arc::new)
            } else {
                None
            };
            if let Some(snapshot) = &restored {
                let mut index = state
                    .index
                    .lock()
                    .map_err(|_| "파일 목록을 읽지 못했습니다.")?;
                if !cancelled() {
                    index.snapshot = Some(snapshot.clone());
                }
                drop(index);
                let _ = app.emit("prism:file-index-changed", ());
            }
            let previous = previous.or(restored);
            let snapshot = if !force && !paths.is_empty() && previous.is_some() {
                file_index::refresh_incremental(
                    &roots,
                    generation,
                    previous.as_deref().unwrap(),
                    &paths,
                    cancelled,
                )
            } else {
                // One reconciliation after restart accounts for changes while closed.
                file_index::refresh(
                    &roots,
                    generation,
                    if force { None } else { previous.as_deref() },
                    cancelled,
                )
            };
            // Disk writes and root revocation share a fence; an old worker cannot
            // recreate a revoked snapshot after the removal command completes.
            let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
            if !cancelled() {
                if let Some(path) = cache_path {
                    // Cache failure degrades to a usable in-memory catalog.
                    let _ = file_index::save_cache(&path, &roots, &snapshot);
                }
            }
            Ok(snapshot)
        })();
        let again = if let Ok(mut index) = state.index.lock() {
            match result {
                Ok(snapshot) => {
                    index.publish(snapshot, state.generation.load(Ordering::SeqCst));
                }
                Err(error) => {
                    index.refreshing = false;
                    if generation == state.generation.load(Ordering::SeqCst) {
                        index.error = Some(error);
                    }
                }
            }
            index.force_pending
                || !index.pending.is_empty()
                || generation != state.generation.load(Ordering::SeqCst)
        } else {
            false
        };
        let _ = app.emit("prism:file-index-changed", ());
        if again {
            let _ = ensure_index(app.clone(), false);
        }
    });
    Ok(())
}
#[tauri::command]
pub async fn library_refresh_files(
    app: tauri::AppHandle,
    _state: State<'_, Library>,
) -> Result<(), String> {
    ensure_index(app, true)
}
fn spotlight_root(app: &tauri::AppHandle) -> Result<Root, String> {
    let home = app
        .path()
        .home_dir()
        .map_err(|_| "홈 폴더를 찾지 못했습니다.")?
        .canonicalize()
        .map_err(|_| "홈 폴더에 접근하지 못했습니다.")?;
    Ok(Root {
        id: "spotlight".into(),
        path: home.to_string_lossy().into_owned(),
    })
}
#[cfg(target_os = "macos")]
async fn spotlight(app: &tauri::AppHandle, query: &str) -> Result<Vec<FileHit>, String> {
    use tokio::io::AsyncReadExt;
    if query.trim().is_empty() {
        return Ok(vec![]);
    }
    let root = spotlight_root(app)?;
    let mut child = tokio::process::Command::new("/usr/bin/mdfind")
        .args(["-0", "-onlyin", &root.path, "-name", query.trim()])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| "Spotlight 검색을 시작하지 못했습니다.")?;
    let output = child.stdout.take().ok_or("파일 검색을 읽지 못했습니다.")?;
    let mut bytes = Vec::new();
    tokio::time::timeout(std::time::Duration::from_millis(200), async {
        output
            .take(1_048_576)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| "파일 검색을 읽지 못했습니다.")?;
        if bytes.len() == 1_048_576 {
            let _ = child.kill().await;
        } else if !child
            .wait()
            .await
            .map_err(|_| "파일 검색을 완료하지 못했습니다.")?
            .success()
        {
            return Err("Spotlight 검색을 완료하지 못했습니다.");
        }
        Ok(())
    })
    .await
    .map_err(|_| "파일 검색 시간이 초과되었습니다. 다시 검색하세요.")??;
    let mut hits = Vec::new();
    let processing_started = std::time::Instant::now();
    for path in bytes
        .split(|b| *b == 0)
        .filter_map(|b| std::str::from_utf8(b).ok())
        .take(800)
    {
        if processing_started.elapsed() >= std::time::Duration::from_millis(50) {
            break;
        }
        let path = Path::new(path);
        let Ok(relative) = path.strip_prefix(&root.path) else {
            continue;
        };
        if relative.as_os_str().is_empty()
            || relative.components().any(|c| {
                let name = c.as_os_str().to_string_lossy();
                file_index::excluded(&name) || name.ends_with(".app")
            })
        {
            continue;
        }
        let Ok(meta) = path.symlink_metadata() else {
            continue;
        };
        if meta.is_symlink() || (!meta.is_file() && !meta.is_dir()) {
            continue;
        }
        hits.push(FileHit {
            id: format!("spotlight:{}", relative.to_string_lossy()),
            name: path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            path: path.to_string_lossy().into_owned(),
            is_directory: meta.is_dir(),
        });
        if hits.len() >= 400 {
            break;
        }
    }
    Ok(hits)
}
#[cfg(not(target_os = "macos"))]
async fn spotlight(_app: &tauri::AppHandle, _query: &str) -> Result<Vec<FileHit>, String> {
    Ok(vec![])
}
#[tauri::command]
pub async fn library_search_files(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    query: String,
    offset: usize,
    limit: usize,
    file_type: Option<String>,
    include_system: Option<bool>,
) -> Result<FileResults, String> {
    if query.len() > 512 {
        return Err("검색어가 너무 깁니다.".into());
    }
    let filter = file_type.as_deref().unwrap_or("all");
    if !["all", "folder", "text", "image", "document"].contains(&filter) {
        return Err("지원하지 않는 파일 종류입니다.".into());
    }
    ensure_index(app.clone(), false)?;
    let generation = state.generation.load(Ordering::SeqCst);
    let (mut items, mut total, mut limited, indexing, mut error) = {
        let index = state
            .index
            .lock()
            .map_err(|_| "파일 목록을 읽지 못했습니다.")?;
        let current = index.current(generation);
        let (items, total) = current
            .map(|s| s.page(&query, filter, offset.min(MAX_FILES), limit.clamp(1, 100)))
            .unwrap_or_default();
        (
            items,
            total,
            current.is_some_and(|s| s.limited),
            index.refreshing || (current.is_none() && index.error.is_none()),
            index.error.clone().or_else(|| index.watcher_error.clone()),
        )
    };
    // Broader search is explicit and merges all local matches before pagination.
    // The fast local request never waits for Spotlight.
    if include_system.unwrap_or(false) && !query.trim().is_empty() {
        match spotlight(&app, &query).await {
            Ok(found) => {
                let matcher = file_index::FilenameQuery::new(&query);
                let mut all = {
                    let index = state
                        .index
                        .lock()
                        .map_err(|_| "파일 목록을 읽지 못했습니다.")?;
                    index
                        .current(generation)
                        .map(|s| s.page(&query, filter, 0, MAX_FILES).0)
                        .unwrap_or_default()
                };
                let mut seen: HashSet<String> = all.iter().map(|f| f.path.clone()).collect();
                all.extend(found.into_iter().filter(|f| {
                    matcher.rank(&search_key(&f.name)).is_some()
                        && matches_file_type(f, filter)
                        && seen.insert(f.path.clone())
                }));
                all.sort_by_cached_key(|f| {
                    let key = search_key(&f.name);
                    (matcher.rank(&key), key, f.path.clone())
                });
                limited = true; // Spotlight is a bounded supplemental source.
                total = all.len();
                items = all
                    .into_iter()
                    .skip(offset.min(MAX_FILES))
                    .take(limit.clamp(1, 100))
                    .collect();
            }
            Err(reason) => {
                limited = true;
                error = Some(reason);
            }
        }
    }
    if generation != state.generation.load(Ordering::SeqCst) {
        return Ok(FileResults {
            items: vec![],
            total: 0,
            limited: true,
            indexing: true,
            error: None,
        });
    }
    for hit in &mut items {
        hit.id = issue_file_id(&state, &hit.id)?;
    }
    Ok(FileResults {
        items,
        total,
        limited,
        indexing,
        error,
    })
}
fn file_path(roots: &[Root], id: &str) -> Result<PathBuf, String> {
    let (root_id, relative) = id.split_once(':').ok_or("올바르지 않은 파일입니다.")?;
    let root = roots
        .iter()
        .find(|r| r.id == root_id)
        .ok_or("검색 폴더가 제거되었습니다.")?;
    let relative = Path::new(relative);
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err("올바르지 않은 파일 경로입니다.".into());
    }
    let base = Path::new(&root.path)
        .canonicalize()
        .map_err(|_| "검색 폴더에 접근하지 못했습니다.")?;
    if base != PathBuf::from(&root.path) {
        return Err("검색 폴더가 이동되었습니다. 폴더를 다시 추가하세요.".into());
    }
    let mut cursor = base.clone();
    for component in relative.components() {
        cursor.push(component.as_os_str());
        if std::fs::symlink_metadata(&cursor)
            .map_err(|_| "파일이 이동되거나 삭제되었습니다. 목록을 새로고침하세요.")?
            .is_symlink()
        {
            return Err("심볼릭 링크는 지원하지 않습니다.".into());
        }
    }
    let path = base
        .join(relative)
        .canonicalize()
        .map_err(|_| "파일이 이동되거나 삭제되었습니다. 목록을 새로고침하세요.")?;
    if !path.starts_with(base) {
        return Err("검색 폴더 밖의 파일입니다.".into());
    }
    Ok(path)
}
fn open_path(path: &Path, reveal: bool) -> Result<(), String> {
    if !path.exists() {
        return Err("파일이 이동되거나 삭제되었습니다.".into());
    }
    #[cfg(target_os = "macos")]
    {
        let mut command = std::process::Command::new("/usr/bin/open");
        if reveal {
            command.arg("-R");
        }
        command
            .arg("--")
            .arg(path)
            .spawn()
            .map_err(|_| "파일을 열지 못했습니다.")?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (path, reveal);
        Err("파일 열기는 현재 macOS에서 지원합니다.".into())
    }
}
#[tauri::command]
pub fn library_file_action(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    id: String,
    action: String,
) -> Result<String, String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    let id = resolve_file_id(&state, &id)?;
    let mut roots = read(&db(&app)?)?.roots;
    if id.starts_with("spotlight:") {
        roots.push(spotlight_root(&app)?);
    }
    let path = file_path(&roots, &id)?;
    match action.as_str() {
        "open" => open_path(&path, false)?,
        "reveal" => open_path(&path, true)?,
        "copy" => {
            arboard::Clipboard::new()
                .map_err(|_| "클립보드에 접근하지 못했습니다.")?
                .set_text(path.to_string_lossy().into_owned())
                .map_err(|_| "경로를 복사하지 못했습니다.")?;
        }
        _ => return Err("지원하지 않는 동작입니다.".into()),
    }
    Ok(path.to_string_lossy().into_owned())
}
#[tauri::command]
pub async fn library_entry_action(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    id: String,
    action: String,
) -> Result<(), String> {
    let entry = {
        let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
        read(&db(&app)?)?
            .entries
            .into_iter()
            .find(|e| e.id == id)
            .ok_or("항목이 삭제되었습니다.")?
    };
    validate_entry(&entry)?;
    if dynamic_entry(&entry) {
        return Err("실행 전에 미리보기를 확인하세요.".into());
    }
    execute_entry(app, entry, action).await
}

async fn execute_entry(app: tauri::AppHandle, entry: Entry, action: String) -> Result<(), String> {
    match action.as_str() {
        "copy" => arboard::Clipboard::new()
            .map_err(|_| "클립보드에 접근하지 못했습니다.")?
            .set_text(entry.value)
            .map_err(|_| "복사하지 못했습니다.".into()),
        "paste" if entry.kind == "snippet" => crate::paste::paste_text(app, entry.value).await,
        "open" if entry.kind == "link" => crate::web::open_web_url(entry.value).map(|_| ()),
        "open" if entry.kind == "path" => open_path(Path::new(&entry.value), false),
        _ => Err("지원하지 않는 동작입니다.".into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_library_migrates_without_losing_text_and_keywords_are_unique() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE entries(id TEXT PRIMARY KEY,kind TEXT NOT NULL,title TEXT NOT NULL,value TEXT NOT NULL); INSERT INTO entries VALUES('legacy','snippet','인사','안녕하세요');").unwrap();
        schema(&db).unwrap();
        schema(&db).unwrap();
        let mut entry = read(&db).unwrap().entries.remove(0);
        assert_eq!(entry.value, "안녕하세요");
        assert_eq!(entry.keyword, None);
        entry.keyword = Some(" ;hello ".into());
        save(&db, &entry).unwrap();
        assert_eq!(
            read(&db).unwrap().entries[0].keyword.as_deref(),
            Some(";hello")
        );
        entry.id = "duplicate".into();
        assert!(save(&db, &entry).is_err());
        assert_eq!(read(&db).unwrap().entries.len(), 1);
        entry.keyword = Some("ordinary".into());
        assert!(save(&db, &entry).is_err());
        entry.keyword = Some(";two words".into());
        assert!(save(&db, &entry).is_err());
        entry.keyword = Some("".into());
        save(&db, &entry).unwrap();
        entry.id = "legacy".into();
        save(&db, &entry).unwrap();
        assert!(read(&db)
            .unwrap()
            .entries
            .iter()
            .all(|entry| entry.keyword.is_none()));
    }
    #[test]
    fn library_roundtrip_and_update_preserve_other_entries() {
        let db = Connection::open_in_memory().unwrap();
        schema(&db).unwrap();
        let mut e = Entry {
            id: "one".into(),
            kind: "snippet".into(),
            title: "인사".into(),
            value: "안녕하세요\n반갑습니다".into(),
            keyword: None,
        };
        save(&db, &e).unwrap();
        e.id = "two".into();
        save(&db, &e).unwrap();
        e.value = "수정".into();
        save(&db, &e).unwrap();
        let data = read(&db).unwrap();
        assert_eq!(data.entries.len(), 2);
        assert!(data.entries.iter().any(|e| e.value.contains("안녕하세요")));
    }
    #[test]
    fn file_search_matches_decomposed_korean_names() {
        assert_eq!(
            search_key("작업 계획.md"),
            search_key(&"작업 계획.md".nfd().collect::<String>())
        );
    }
    #[test]
    fn reject_executable_schemes_and_invalid_records() {
        for url in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://user:pass@example.com",
        ] {
            assert!(validate_entry(&Entry {
                id: "one".into(),
                kind: "link".into(),
                title: "Test".into(),
                value: url.into(),
                keyword: None,
            })
            .is_err());
        }
    }
    #[test]
    fn scan_is_bounded_and_revalidates_roots() {
        let dir = std::env::temp_dir().join(format!("prism-file-fixture-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("node_modules")).unwrap();
        std::fs::write(dir.join("메모.txt"), "hello").unwrap();
        std::fs::write(dir.join("node_modules/hidden.txt"), "skip").unwrap();
        let roots = vec![Root {
            id: "fixture".into(),
            path: dir.canonicalize().unwrap().to_string_lossy().into_owned(),
        }];
        let (files, limited) = scan(&roots, || false);
        assert!(!limited);
        assert_eq!(files.len(), 1);
        assert!(file_path(&roots, "fixture:../outside").is_err());
        assert!(file_path(&[], &files[0].id).is_err());
        assert!(file_path(&roots, &files[0].id)
            .unwrap()
            .ends_with("메모.txt"));
        assert!(scan(&roots, || true).0.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}

// File action IDs are session-issued capabilities, never frontend-supplied paths.
fn opaque_token(state: &Library, value: &str) -> String {
    let mut hash = state.token_hash.build_hasher();
    state
        .token_counter
        .fetch_add(1, Ordering::Relaxed)
        .hash(&mut hash);
    value.hash(&mut hash);
    format!("{:016x}", hash.finish())
}
fn issue_file_id(state: &Library, source: &str) -> Result<String, String> {
    let mut issued = state
        .issued
        .lock()
        .map_err(|_| "파일 목록을 읽지 못했습니다.")?;
    if let Some((id, _)) = issued.iter().find(|(_, value)| value == source) {
        return Ok(id.clone());
    }
    let id = opaque_token(state, source);
    if issued.len() >= 4096 {
        issued.pop_front();
    }
    issued.push_back((id.clone(), source.into()));
    Ok(id)
}
fn resolve_file_id(state: &Library, id: &str) -> Result<String, String> {
    state
        .issued
        .lock()
        .map_err(|_| "파일 목록을 읽지 못했습니다.")?
        .iter()
        .find(|(token, _)| token == id)
        .map(|(_, source)| source.clone())
        .ok_or_else(|| "파일 목록이 만료되었습니다. 목록을 새로고침하세요.".into())
}
fn extension(name: &str) -> String {
    Path::new(name)
        .extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_ascii_lowercase()
}
fn text_extension(ext: &str) -> bool {
    [
        "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "ini",
        "log", "rs", "js", "jsx", "ts", "tsx", "py", "swift", "kt", "java", "css", "html", "xml",
        "sh", "sql",
    ]
    .contains(&ext)
}
fn matches_file_type(file: &FileHit, filter: &str) -> bool {
    if filter == "all" {
        return true;
    }
    if file.is_directory {
        return filter == "folder";
    }
    let ext = extension(&file.name);
    match filter {
        "text" => text_extension(&ext),
        "image" => [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg",
        ]
        .contains(&ext.as_str()),
        "document" => [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt",
            "rtf",
        ]
        .contains(&ext.as_str()),
        _ => false,
    }
}

const MAX_TEXT_PREVIEW: usize = 64 * 1024;
const MAX_IMAGE_PREVIEW: usize = 2 * 1024 * 1024;
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FilePreview {
    id: String,
    name: String,
    path: String,
    is_directory: bool,
    extension: String,
    size: u64,
    modified_at: Option<u64>,
    kind: &'static str,
    text: Option<String>,
    image_data_url: Option<String>,
    truncated: bool,
}

// Walk every component from the filesystem root using directory descriptors.
// O_NOFOLLOW prevents symlink substitution, O_NONBLOCK prevents FIFO hangs.
#[cfg(unix)]
fn open_preview_file(path: &Path) -> Result<std::fs::File, String> {
    use std::os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::OsStrExt,
    };
    let mut file = std::fs::File::open("/").map_err(|_| "파일에 접근하지 못했습니다.")?;
    let components: Vec<_> = path.components().collect();
    for (index, component) in components.iter().enumerate() {
        if matches!(component, std::path::Component::RootDir) {
            continue;
        }
        if !matches!(component, std::path::Component::Normal(_)) {
            return Err("올바르지 않은 파일 경로입니다.".into());
        }
        let name = std::ffi::CString::new(component.as_os_str().as_bytes())
            .map_err(|_| "올바르지 않은 파일 경로입니다.")?;
        let flags = libc::O_RDONLY
            | libc::O_NOFOLLOW
            | libc::O_CLOEXEC
            | libc::O_NONBLOCK
            | if index + 1 < components.len() {
                libc::O_DIRECTORY
            } else {
                0
            };
        let descriptor = unsafe { libc::openat(file.as_raw_fd(), name.as_ptr(), flags) };
        if descriptor < 0 {
            return Err("파일에 접근하지 못했습니다.".into());
        }
        file = unsafe { std::fs::File::from_raw_fd(descriptor) };
    }
    Ok(file)
}
#[cfg(not(unix))]
fn open_preview_file(path: &Path) -> Result<std::fs::File, String> {
    if path
        .symlink_metadata()
        .map_err(|_| "파일에 접근하지 못했습니다.")?
        .is_symlink()
    {
        return Err("심볼릭 링크는 지원하지 않습니다.".into());
    }
    std::fs::File::open(path).map_err(|_| "파일에 접근하지 못했습니다.".into())
}

fn build_preview(path: &Path, id: String) -> Result<FilePreview, String> {
    let file = open_preview_file(path)?;
    let metadata = file
        .metadata()
        .map_err(|_| "파일 정보를 읽지 못했습니다.")?;
    if !metadata.is_file() && !metadata.is_dir() {
        return Err("일반 파일만 미리볼 수 있습니다.".into());
    }
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let ext = extension(&name);
    let mut preview = FilePreview {
        id,
        name,
        path: path.to_string_lossy().into_owned(),
        is_directory: metadata.is_dir(),
        extension: ext.clone(),
        size: metadata.len(),
        modified_at: metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_millis() as u64),
        kind: if metadata.is_dir() {
            "directory"
        } else {
            "unsupported"
        },
        text: None,
        image_data_url: None,
        truncated: false,
    };
    if metadata.is_dir() {
        return Ok(preview);
    }
    if text_extension(&ext) {
        let mut bytes = Vec::new();
        file.take((MAX_TEXT_PREVIEW + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| "미리보기를 읽지 못했습니다.")?;
        preview.truncated = bytes.len() > MAX_TEXT_PREVIEW;
        bytes.truncate(MAX_TEXT_PREVIEW);
        // A cut through a multibyte final character is expected at the byte limit.
        let text = match std::str::from_utf8(&bytes) {
            Ok(value) => Some(value),
            Err(error) if preview.truncated && error.error_len().is_none() => {
                std::str::from_utf8(&bytes[..error.valid_up_to()]).ok()
            }
            Err(_) => None,
        };
        if let Some(text) = text.filter(|text| {
            !text
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
        }) {
            preview.kind = "text";
            preview.text = Some(text.into());
        }
    } else if ["png", "jpg", "jpeg", "webp"].contains(&ext.as_str())
        && metadata.len() <= MAX_IMAGE_PREVIEW as u64
    {
        let mut bytes = Vec::new();
        file.take((MAX_IMAGE_PREVIEW + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| "미리보기를 읽지 못했습니다.")?;
        if bytes.len() <= MAX_IMAGE_PREVIEW {
            preview.image_data_url = raster_thumbnail(&bytes);
        }
        if preview.image_data_url.is_some() {
            preview.kind = "image";
        }
    }
    Ok(preview)
}
#[cfg(target_os = "macos")]
fn raster_thumbnail(bytes: &[u8]) -> Option<String> {
    use base64::Engine;
    let format = image::guess_format(bytes).ok()?;
    if !matches!(
        format,
        image::ImageFormat::Png | image::ImageFormat::Jpeg | image::ImageFormat::WebP
    ) {
        return None;
    }
    let mut reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let thumbnail = reader.decode().ok()?.thumbnail(720, 720);
    let mut output = std::io::Cursor::new(Vec::new());
    thumbnail
        .write_to(&mut output, image::ImageFormat::Png)
        .ok()?;
    Some(format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(output.into_inner())
    ))
}
#[cfg(not(target_os = "macos"))]
fn raster_thumbnail(_bytes: &[u8]) -> Option<String> {
    None
}

#[tauri::command]
pub async fn library_preview_file(
    app: tauri::AppHandle,
    id: String,
) -> Result<FilePreview, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Library>();
        // Root removal cannot race a preview read.
        let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
        let source = resolve_file_id(&state, &id)?;
        let mut roots = read(&db(&app)?)?.roots;
        if source.starts_with("spotlight:") {
            roots.push(spotlight_root(&app)?);
        }
        let path = file_path(&roots, &source)?;
        build_preview(&path, id)
    })
    .await
    .map_err(|_| "미리보기를 읽지 못했습니다.".to_string())?
}

#[derive(Clone)]
struct PreparedRun {
    entry: Entry,
    value: String,
    created: std::time::Instant,
}
#[derive(Serialize)]
pub struct PreparedEntry {
    token: String,
    value: String,
}
fn dynamic_entry(entry: &Entry) -> bool {
    (entry.kind == "link" && entry.value.contains("{query}"))
        || (entry.kind == "snippet"
            && ["{date}", "{time}", "{clipboard}"]
                .iter()
                .any(|token| entry.value.contains(token)))
}
fn validate_link_template(value: &str) -> Result<(), String> {
    // Query placeholders belong only to the URL query, never scheme, host, or path.
    if value.contains("{query}") {
        let (_, query) = value
            .split_once('?')
            .ok_or("검색어 자리표시는 URL 쿼리에만 사용할 수 있습니다.")?;
        if value
            .split('?')
            .next()
            .unwrap_or_default()
            .contains("{query}")
            || query
                .split_once('#')
                .is_some_and(|(_, fragment)| fragment.contains("{query}"))
        {
            return Err("검색어 자리표시는 URL 쿼리에만 사용할 수 있습니다.".into());
        }
    }
    crate::web::validated_http_url(&value.replace("{query}", "prism"))?;
    Ok(())
}
fn encode_query(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(byte) {
            encoded.push(*byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}
fn expand_entry(
    entry: &Entry,
    query: Option<&str>,
    date: &str,
    time: &str,
    clipboard: &str,
) -> Result<String, String> {
    if entry.kind == "link" && entry.value.contains("{query}") {
        let query = query
            .filter(|value| !value.trim().is_empty() && value.len() <= 8192)
            .ok_or("검색어를 입력하세요.")?;
        let value = entry.value.replace("{query}", &encode_query(query));
        crate::web::validated_http_url(&value)?;
        return Ok(value);
    }
    if entry.kind != "snippet" {
        return Ok(entry.value.clone());
    }
    // A single pass ensures clipboard content is never interpreted as a template.
    let mut result = String::new();
    let mut rest = entry.value.as_str();
    while let Some(index) = rest.find('{') {
        result.push_str(&rest[..index]);
        rest = &rest[index..];
        let replacement = [
            ("{date}", date),
            ("{time}", time),
            ("{clipboard}", clipboard),
        ]
        .into_iter()
        .find(|(token, _)| rest.starts_with(token));
        if let Some((token, value)) = replacement {
            result.push_str(value);
            rest = &rest[token.len()..];
        } else {
            result.push('{');
            rest = &rest[1..];
        }
        if result.len() > 128 * 1024 {
            return Err("확장한 내용은 최대 128 KB입니다.".into());
        }
    }
    result.push_str(rest);
    if result.len() > 128 * 1024 {
        return Err("확장한 내용은 최대 128 KB입니다.".into());
    }
    Ok(result)
}
fn local_date_time() -> (String, String) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    #[cfg(unix)]
    {
        let timestamp = now as libc::time_t;
        let mut local = std::mem::MaybeUninit::<libc::tm>::uninit();
        if !unsafe { libc::localtime_r(&timestamp, local.as_mut_ptr()) }.is_null() {
            let local = unsafe { local.assume_init() };
            return (
                format!(
                    "{:04}-{:02}-{:02}",
                    local.tm_year + 1900,
                    local.tm_mon + 1,
                    local.tm_mday
                ),
                format!("{:02}:{:02}", local.tm_hour, local.tm_min),
            );
        }
    }
    let utc = chrono::DateTime::from_timestamp(now as i64, 0).unwrap_or_default();
    (
        utc.format("%Y-%m-%d").to_string(),
        utc.format("%H:%M").to_string(),
    )
}
#[tauri::command]
pub fn library_prepare_entry(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    id: String,
    query: Option<String>,
) -> Result<PreparedEntry, String> {
    let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
    let entry = read(&db(&app)?)?
        .entries
        .into_iter()
        .find(|entry| entry.id == id)
        .ok_or("항목이 삭제되었습니다.")?;
    validate_entry(&entry)?;
    let clipboard = if entry.kind == "snippet" && entry.value.contains("{clipboard}") {
        arboard::Clipboard::new()
            .map_err(|_| "클립보드에 접근하지 못했습니다.")?
            .get_text()
            .map_err(|_| "클립보드에 텍스트가 없습니다.")?
    } else {
        String::new()
    };
    if clipboard.len() > 128 * 1024 {
        return Err("클립보드 텍스트가 너무 깁니다.".into());
    }
    let (date, time) = local_date_time();
    let value = expand_entry(&entry, query.as_deref(), &date, &time, &clipboard)?;
    let token = opaque_token(&state, &id);
    let mut prepared = state
        .prepared
        .lock()
        .map_err(|_| "보관함이 사용 중입니다.")?;
    prepared.retain(|_, run| run.created.elapsed().as_secs() < 300);
    if prepared.len() >= 32 {
        prepared.clear();
    }
    prepared.insert(
        token.clone(),
        PreparedRun {
            entry,
            value: value.clone(),
            created: std::time::Instant::now(),
        },
    );
    Ok(PreparedEntry { token, value })
}
fn consume_prepared(
    state: &Library,
    id: &str,
    token: &str,
    current: &Entry,
) -> Result<Entry, String> {
    let run = state
        .prepared
        .lock()
        .map_err(|_| "보관함이 사용 중입니다.")?
        .remove(token)
        .ok_or("미리보기가 만료되었습니다. 다시 불러오세요.")?;
    if run.created.elapsed().as_secs() >= 300
        || run.entry.id != id
        || current.id != id
        || current.kind != run.entry.kind
        || current.value != run.entry.value
        || current.title != run.entry.title
    {
        return Err("항목이 변경되었습니다. 미리보기를 다시 불러오세요.".into());
    }
    Ok(Entry {
        value: run.value,
        ..current.clone()
    })
}
#[tauri::command]
pub async fn library_run_entry(
    app: tauri::AppHandle,
    state: State<'_, Library>,
    id: String,
    action: String,
    token: String,
) -> Result<(), String> {
    let entry = {
        let _guard = state.lock.lock().map_err(|_| "보관함이 사용 중입니다.")?;
        let current = read(&db(&app)?)?
            .entries
            .into_iter()
            .find(|entry| entry.id == id)
            .ok_or("항목이 삭제되었습니다.")?;
        consume_prepared(&state, &id, &token, &current)?
    };
    execute_entry(app, entry, action).await
}

#[cfg(test)]
mod preview_tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "prism-preview-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path.canonicalize().unwrap())
        }
        fn roots(&self) -> Vec<Root> {
            vec![Root {
                id: "root".into(),
                path: self.0.to_string_lossy().into(),
            }]
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn opaque_ids_require_issuance_and_revalidate_removed_roots() {
        let state = Library::default();
        let id = issue_file_id(&state, "root:private.txt").unwrap();
        assert!(!id.contains("private"));
        assert_eq!(issue_file_id(&state, "root:private.txt").unwrap(), id);
        assert_eq!(resolve_file_id(&state, &id).unwrap(), "root:private.txt");
        assert!(resolve_file_id(&state, "root:private.txt").is_err());
        assert!(file_path(&[], &resolve_file_id(&state, &id).unwrap()).is_err());
    }
    #[test]
    fn preview_bounds_text_and_never_renders_binary_or_html() {
        let fixture = Fixture::new();
        let path = fixture.0.join("large.txt");
        std::fs::write(&path, "가".repeat(MAX_TEXT_PREVIEW)).unwrap();
        let preview = build_preview(&path, "id".into()).unwrap();
        assert_eq!(preview.kind, "text");
        assert!(preview.truncated);
        assert!(preview.text.unwrap().len() <= MAX_TEXT_PREVIEW);
        let path = fixture.0.join("binary.txt");
        std::fs::write(&path, b"hello\0binary").unwrap();
        assert_eq!(
            build_preview(&path, "id".into()).unwrap().kind,
            "unsupported"
        );
        let path = fixture.0.join("page.html");
        std::fs::write(&path, "<script>alert(1)</script>").unwrap();
        let preview = build_preview(&path, "id".into()).unwrap();
        assert_eq!(preview.kind, "text");
        assert_eq!(preview.text.unwrap(), "<script>alert(1)</script>");
        assert_eq!(
            build_preview(&fixture.0, "id".into()).unwrap().kind,
            "directory"
        );
    }
    #[cfg(unix)]
    #[test]
    fn preview_rejects_symlink_escape_and_special_files() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        std::fs::write(fixture.0.join("real.txt"), "safe").unwrap();
        symlink("real.txt", fixture.0.join("link.txt")).unwrap();
        assert!(file_path(&fixture.roots(), "root:link.txt").is_err());
        assert!(build_preview(&fixture.0.join("link.txt"), "id".into()).is_err());
        assert!(file_path(&fixture.roots(), "root:../outside.txt").is_err());
        assert!(file_path(&fixture.roots(), "root:").is_err());
        let fifo = fixture.0.join("fifo.txt");
        use std::os::unix::ffi::OsStrExt;
        let name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(build_preview(&fifo, "id".into()).is_err());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn image_preview_reencodes_png_and_rejects_invalid_or_oversized_data() {
        let mut data = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(8, 8)
            .write_to(&mut data, image::ImageFormat::Png)
            .unwrap();
        assert!(raster_thumbnail(data.get_ref())
            .unwrap()
            .starts_with("data:image/png;base64,"));
        assert!(raster_thumbnail(b"<svg onload='alert(1)'/>").is_none());
        for format in [image::ImageFormat::Jpeg, image::ImageFormat::WebP] {
            let mut raster = std::io::Cursor::new(Vec::new());
            image::DynamicImage::new_rgb8(8, 8)
                .write_to(&mut raster, format)
                .unwrap();
            assert!(raster_thumbnail(raster.get_ref())
                .unwrap()
                .starts_with("data:image/png;base64,"));
        }
        let mut too_wide = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(4097, 1)
            .write_to(&mut too_wide, image::ImageFormat::Png)
            .unwrap();
        assert!(raster_thumbnail(too_wide.get_ref()).is_none());
        let fixture = Fixture::new();
        let path = fixture.0.join("large.png");
        std::fs::write(&path, vec![0u8; MAX_IMAGE_PREVIEW + 1]).unwrap();
        assert_eq!(
            build_preview(&path, "id".into()).unwrap().kind,
            "unsupported"
        );
    }
    #[test]
    fn file_filters_distinguish_directories_and_extensions() {
        let mut file = FileHit {
            id: "id".into(),
            name: "notes.MD".into(),
            path: "/notes.MD".into(),
            is_directory: false,
        };
        assert!(matches_file_type(&file, "text"));
        assert!(!matches_file_type(&file, "image"));
        file.name = "photo.PNG".into();
        assert!(matches_file_type(&file, "image"));
        file.is_directory = true;
        assert!(!matches_file_type(&file, "image"));
        assert!(matches_file_type(&file, "folder"));
    }
    fn entry(kind: &str, value: &str) -> Entry {
        Entry {
            id: "entry".into(),
            kind: kind.into(),
            title: "Example".into(),
            value: value.into(),
            keyword: None,
        }
    }
    #[test]
    fn quicklink_query_is_encoded_without_changing_url_authority() {
        let template = entry("link", "https://example.com/search?q={query}&source=prism");
        validate_entry(&template).unwrap();
        assert_eq!(
            expand_entry(&template, Some("가 &x=#"), "", "", "").unwrap(),
            "https://example.com/search?q=%EA%B0%80%20%26x%3D%23&source=prism"
        );
        assert!(expand_entry(&template, Some(" "), "", "", "").is_err());
        for value in [
            "https://{query}/",
            "https://example.com/{query}",
            "https://example.com/?q=a#{query}",
            "javascript:{query}",
        ] {
            assert!(validate_entry(&entry("link", value)).is_err(), "{value}");
        }
    }
    #[test]
    fn snippet_placeholders_expand_once_with_bounded_output() {
        let template = entry("snippet", "{date} {time} {clipboard} {unknown}");
        assert_eq!(
            expand_entry(&template, None, "2026-09-09", "15:00", "{date}").unwrap(),
            "2026-09-09 15:00 {date} {unknown}"
        );
        assert!(expand_entry(&template, None, "", "", &"a".repeat(128 * 1024)).is_err());
    }
    #[test]
    fn execution_consumes_preview_once_and_rejects_changed_templates() {
        let state = Library::default();
        let original = entry("snippet", "{clipboard}");
        state.prepared.lock().unwrap().insert(
            "token".into(),
            PreparedRun {
                entry: original.clone(),
                value: "confirmed text".into(),
                created: std::time::Instant::now(),
            },
        );
        assert_eq!(
            consume_prepared(&state, "entry", "token", &original)
                .unwrap()
                .value,
            "confirmed text"
        );
        assert!(consume_prepared(&state, "entry", "token", &original).is_err());
        state.prepared.lock().unwrap().insert(
            "second".into(),
            PreparedRun {
                entry: original.clone(),
                value: "confirmed text".into(),
                created: std::time::Instant::now(),
            },
        );
        assert!(consume_prepared(&state, "entry", "second", &entry("snippet", "changed")).is_err());
        state.prepared.lock().unwrap().insert(
            "expired".into(),
            PreparedRun {
                entry: original.clone(),
                value: "confirmed text".into(),
                created: std::time::Instant::now() - std::time::Duration::from_secs(301),
            },
        );
        assert!(consume_prepared(&state, "entry", "expired", &original).is_err());
    }
}
