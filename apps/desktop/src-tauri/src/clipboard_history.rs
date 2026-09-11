use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::State;

const HISTORY_CAPACITY: usize = 1000;
static PREVIEW_PERMIT: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);
static ACTION_PREPARATION_PERMIT: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
const MAX_TEXT_BYTES: usize = 128 * 1024;
const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
#[cfg(target_os = "macos")]
const MAX_TIFF_INPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_IMAGE_DIMENSION: u32 = 8192;
const MAX_IMAGE_PIXELS: u64 = 16_000_000;
const MAX_FILE_REFERENCES: usize = 64;
const MAX_REFERENCE_BYTES: usize = 64 * 1024;
const MAX_STORED_BYTES: usize = 128 * 1024 * 1024;
const ENTRY_COLUMNS: &str =
    "id,text,captured_at_ms,pinned,kind,mime_type,byte_size,width,height,file_count";
const SEARCH_PREVIEW_CHARACTERS: usize = 500;
const POLL_INTERVAL: Duration = Duration::from_millis(650);
const DAY_MS: u64 = 86_400_000;
const STORAGE_ERROR: &str = "Clipboard history could not be saved. Check available disk space and storage permissions, then retry.";
const UNAVAILABLE: &str = "Clipboard history storage is unavailable. Restart Prism to retry.";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClipboardKind {
    Text,
    Image,
    Files,
}
impl ClipboardKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Image => "image",
            Self::Files => "files",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardHistoryEntry {
    id: u64,
    text: String,
    captured_at_ms: u64,
    pinned: bool,
    kind: ClipboardKind,
    mime_type: Option<String>,
    byte_size: usize,
    width: Option<u32>,
    height: Option<u32>,
    file_count: usize,
    available: Option<bool>,
}
type ClipboardHistorySearchResult = ClipboardHistoryEntry;

/// Search never returns original image bytes or file URL payloads to the WebView.
#[derive(Clone, Debug)]
pub(crate) enum ClipboardPayload {
    Text(String),
    Image {
        bytes: Vec<u8>,
        mime_type: String,
        width: u32,
        height: u32,
    },
    Files(Vec<String>),
}
impl ClipboardPayload {
    fn stored(
        &self,
    ) -> Result<
        (
            ClipboardKind,
            String,
            Vec<u8>,
            Option<String>,
            Option<u32>,
            Option<u32>,
            usize,
        ),
        String,
    > {
        match self {
            Self::Text(text) if should_capture(text) => Ok((
                ClipboardKind::Text,
                text.clone(),
                vec![],
                None,
                None,
                None,
                0,
            )),
            Self::Image {
                bytes,
                mime_type,
                width,
                height,
            } if !bytes.is_empty()
                && bytes.len() <= MAX_IMAGE_BYTES
                && valid_dimensions(*width, *height)
                && matches!(
                    mime_type.as_str(),
                    "image/png" | "image/jpeg" | "image/webp"
                ) =>
            {
                Ok((
                    ClipboardKind::Image,
                    format!(
                        "{} image · {} × {}",
                        mime_type.trim_start_matches("image/").to_uppercase(),
                        width,
                        height
                    ),
                    bytes.clone(),
                    Some(mime_type.clone()),
                    Some(*width),
                    Some(*height),
                    0,
                ))
            }
            Self::Files(urls) => {
                let paths = parse_file_references(urls)?;
                let bytes = serde_json::to_vec(urls).map_err(|_| "Invalid file references.")?;
                if bytes.len() > MAX_REFERENCE_BYTES {
                    return Err("File references exceed the clipboard size limit.".into());
                }
                let label = paths
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join("\n");
                Ok((
                    ClipboardKind::Files,
                    label,
                    bytes,
                    None,
                    None,
                    None,
                    urls.len(),
                ))
            }
            _ => Err("Clipboard content exceeds supported limits.".into()),
        }
    }
}
fn valid_dimensions(width: u32, height: u32) -> bool {
    width > 0
        && height > 0
        && width <= MAX_IMAGE_DIMENSION
        && height <= MAX_IMAGE_DIMENSION
        && u64::from(width) * u64::from(height) <= MAX_IMAGE_PIXELS
}
fn parse_file_references(urls: &[String]) -> Result<Vec<PathBuf>, String> {
    if urls.is_empty()
        || urls.len() > MAX_FILE_REFERENCES
        || urls.iter().map(String::len).sum::<usize>() > MAX_REFERENCE_BYTES
    {
        return Err("File references exceed the clipboard size limit.".into());
    }
    urls.iter()
        .map(|value| {
            let url = reqwest::Url::parse(value).map_err(|_| "Invalid file reference.")?;
            if url.scheme() != "file"
                || url
                    .host_str()
                    .is_some_and(|h| !h.is_empty() && h != "localhost")
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err("Only local file references are supported.".into());
            }
            let path = url
                .to_file_path()
                .map_err(|_| "Invalid local file reference.")?;
            if !path.is_absolute() {
                return Err("Invalid local file reference.".into());
            }
            Ok(path)
        })
        .collect()
}
// Filesystem work belongs outside HistoryStore's global mutex.
fn validate_file_references(urls: &[String]) -> Result<Vec<PathBuf>, String> {
    let paths = parse_file_references(urls)?;
    if paths.iter().any(|path| !path.try_exists().unwrap_or(false)) {
        return Err(
            "A referenced file is missing or unavailable. Restore it before copying or pasting."
                .into(),
        );
    }
    Ok(paths)
}

/// File availability has been checked outside the history lock for this action.
#[derive(Clone)]
pub(crate) struct PreparedClipboardPayload(ClipboardPayload);
impl PreparedClipboardPayload {
    pub(crate) fn new(payload: ClipboardPayload) -> Result<Self, String> {
        if let ClipboardPayload::Files(urls) = &payload {
            validate_file_references(urls)?;
        }
        Ok(Self(payload))
    }
}

fn entry_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ClipboardHistoryEntry> {
    let kind: String = row.get(4)?;
    let kind = match kind.as_str() {
        "text" => ClipboardKind::Text,
        "image" => ClipboardKind::Image,
        "files" => ClipboardKind::Files,
        _ => return Err(rusqlite::Error::InvalidQuery),
    };
    Ok(ClipboardHistoryEntry {
        id: row.get(0)?,
        text: row.get(1)?,
        captured_at_ms: row.get(2)?,
        pinned: row.get(3)?,
        kind,
        mime_type: row.get(5)?,
        byte_size: row.get(6)?,
        width: row.get(7)?,
        height: row.get(8)?,
        file_count: row.get(9)?,
        available: (kind != ClipboardKind::Files).then_some(true),
    })
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardHistorySettings {
    enabled: bool,
    retention_days: u32,
    entry_count: usize,
    pinned_count: usize,
    capacity: usize,
    persistence_error: Option<String>,
    capture_notice: Option<String>,
}

#[derive(Default)]
struct HistoryStore {
    connection: Option<Connection>,
    enabled: bool,
    retention_days: u32,
    generation: u64,
    persistence_error: Option<String>,
    capture_notice: Option<String>,
}

impl HistoryStore {
    fn open(path: PathBuf) -> Result<Self, String> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|_| UNAVAILABLE.to_string())?;
        }
        // Create the database privately before SQLite opens it; do not log database contents/errors.
        let mut options = std::fs::OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(&path).map_err(|_| UNAVAILABLE.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| UNAVAILABLE.to_string())?;
        }
        let connection = Connection::open(path).map_err(|_| UNAVAILABLE.to_string())?;
        Self::from_connection(connection)
    }

    fn from_connection(connection: Connection) -> Result<Self, String> {
        connection
            .busy_timeout(Duration::from_secs(2))
            .map_err(|_| UNAVAILABLE.to_string())?;
        connection.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS clipboard_settings (
                id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL DEFAULT 0,
                retention_days INTEGER NOT NULL DEFAULT 30 CHECK(retention_days IN (1,7,30,90)));
            INSERT OR IGNORE INTO clipboard_settings(id) VALUES(1);
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE,
                captured_at_ms INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)));
            CREATE INDEX IF NOT EXISTS clipboard_entries_recency ON clipboard_entries(captured_at_ms DESC, id DESC);")
            .map_err(|_| UNAVAILABLE.to_string())?;
        // Migrate transactionally; retain IDs, pins, consent, timestamps and AUTOINCREMENT high water.
        let rich_schema: bool = connection
            .prepare("PRAGMA table_info(clipboard_entries)")
            .map_err(|_| UNAVAILABLE)?
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|_| UNAVAILABLE)?
            .filter_map(Result::ok)
            .any(|name| name == "kind");
        if !rich_schema {
            connection.execute_batch("BEGIN IMMEDIATE;
                CREATE TEMP TABLE clipboard_old_sequence AS SELECT seq FROM sqlite_sequence WHERE name='clipboard_entries';
                DROP INDEX IF EXISTS clipboard_entries_recency;
                ALTER TABLE clipboard_entries RENAME TO clipboard_entries_v1;
                CREATE TABLE clipboard_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL,
                    captured_at_ms INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
                    kind TEXT NOT NULL DEFAULT 'text' CHECK(kind IN ('text','image','files')),
                    payload BLOB NOT NULL DEFAULT X'', mime_type TEXT, byte_size INTEGER NOT NULL DEFAULT 0,
                    width INTEGER, height INTEGER, file_count INTEGER NOT NULL DEFAULT 0);
                INSERT INTO clipboard_entries(id,text,captured_at_ms,pinned,byte_size)
                    SELECT id,text,captured_at_ms,pinned,length(CAST(text AS BLOB)) FROM clipboard_entries_v1;
                UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM clipboard_old_sequence),0)) WHERE name='clipboard_entries';
                INSERT INTO sqlite_sequence(name,seq) SELECT 'clipboard_entries',seq FROM clipboard_old_sequence WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='clipboard_entries');
                DROP TABLE clipboard_entries_v1;
                DROP TABLE clipboard_old_sequence;
                CREATE INDEX clipboard_entries_recency ON clipboard_entries(captured_at_ms DESC,id DESC);
                PRAGMA user_version=2;
                COMMIT;") .map_err(|_| UNAVAILABLE.to_string())?;
        }
        // Existing v1 text indexes duplicated content. Compact the one-time migration before
        // enforcing the rich-store high water, without dropping any retained text or pins.
        let auto_vacuum: u32 = connection
            .query_row("PRAGMA auto_vacuum", [], |r| r.get(0))
            .map_err(|_| UNAVAILABLE)?;
        if auto_vacuum != 2 {
            connection
                .execute_batch("PRAGMA auto_vacuum=INCREMENTAL; VACUUM;")
                .map_err(|_| UNAVAILABLE)?;
        }
        // Bound the database high water even after repeated deletion; rollback journal is transient.
        let page_size: usize = connection
            .query_row("PRAGMA page_size", [], |r| r.get(0))
            .map_err(|_| UNAVAILABLE)?;
        let max_pages = 192 * 1024 * 1024 / page_size;
        connection
            .pragma_update(None, "max_page_count", max_pages)
            .map_err(|_| UNAVAILABLE)?;
        let actual_max_pages: usize = connection
            .query_row("PRAGMA max_page_count", [], |r| r.get(0))
            .map_err(|_| UNAVAILABLE)?;
        if actual_max_pages > max_pages {
            return Err(UNAVAILABLE.into());
        }
        let (enabled, retention_days) = connection
            .query_row(
                "SELECT enabled,retention_days FROM clipboard_settings WHERE id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|_| UNAVAILABLE.to_string())?;
        let mut store = Self {
            connection: Some(connection),
            enabled,
            retention_days,
            ..Self::default()
        };
        if !enabled {
            store.clear()?;
        }
        store.prune(now_ms())?;
        Ok(store)
    }

    fn db(&self) -> Result<&Connection, String> {
        self.connection
            .as_ref()
            .ok_or_else(|| UNAVAILABLE.to_string())
    }

    fn transaction<T>(
        &mut self,
        operation: impl FnOnce(&rusqlite::Transaction<'_>) -> rusqlite::Result<T>,
    ) -> Result<T, String> {
        let result: rusqlite::Result<T> = (|| {
            let connection = self
                .connection
                .as_mut()
                .ok_or(rusqlite::Error::InvalidQuery)?;
            let transaction = connection.transaction()?;
            let value = operation(&transaction)?;
            transaction.commit()?;
            Ok(value)
        })();
        match result {
            Ok(value) => {
                // Deletion already committed; reclaim some free pages without misreporting
                // a successful destructive operation if optional compaction fails.
                if let Some(db) = self.connection.as_ref() {
                    let _ = db.execute_batch("PRAGMA incremental_vacuum(256)");
                }
                self.persistence_error = None;
                Ok(value)
            }
            Err(_) => {
                self.persistence_error = Some(STORAGE_ERROR.to_string());
                Err(STORAGE_ERROR.to_string())
            }
        }
    }

    fn prune(&mut self, at: u64) -> Result<(), String> {
        let cutoff = at.saturating_sub(u64::from(self.retention_days) * DAY_MS);
        let prior_error = self.persistence_error.clone();
        self.transaction(|tx| {
            tx.execute(
                "DELETE FROM clipboard_entries WHERE pinned=0 AND captured_at_ms < ?1",
                [cutoff],
            )?;
            Ok(())
        })?;
        self.persistence_error = prior_error;
        Ok(())
    }

    #[cfg(test)]
    fn record(&mut self, text: String, at: u64) -> Result<(), String> {
        if !self.enabled || !should_capture(&text) {
            return Ok(());
        }
        self.record_payload(ClipboardPayload::Text(text), at)
    }

    fn record_payload(&mut self, payload: ClipboardPayload, at: u64) -> Result<(), String> {
        if !self.enabled {
            return Ok(());
        }
        let (kind, text, bytes, mime_type, width, height, file_count) = payload.stored()?;
        let size = text.len() + bytes.len();
        let cutoff = at.saturating_sub(u64::from(self.retention_days) * DAY_MS);
        let saved = self.transaction(|tx| {
            tx.execute("DELETE FROM clipboard_entries WHERE pinned=0 AND captured_at_ms < ?1", [cutoff])?;
            let existing: Option<u64> = tx.query_row("SELECT id FROM clipboard_entries WHERE kind=?1 AND text=?2 AND payload=?3", params![kind.as_str(), text, bytes], |r| r.get(0)).optional()?;
            if let Some(id) = existing {
                tx.execute("UPDATE clipboard_entries SET captured_at_ms=?1 WHERE id=?2", params![at,id])?;
                return Ok(true);
            }
            // Check pins first so an entry we cannot accept never removes unrelated unpinned history.
            let (pins, pinned_bytes): (usize, usize) = tx.query_row("SELECT COUNT(*),COALESCE(SUM(byte_size),0) FROM clipboard_entries WHERE pinned=1", [], |r| Ok((r.get(0)?,r.get(1)?)))?;
            if pins >= HISTORY_CAPACITY || pinned_bytes.saturating_add(size) > MAX_STORED_BYTES { return Ok(false); }
            loop {
                let (count, total): (usize,usize) = tx.query_row("SELECT COUNT(*),COALESCE(SUM(byte_size),0) FROM clipboard_entries", [], |r| Ok((r.get(0)?,r.get(1)?)))?;
                if count < HISTORY_CAPACITY && total.saturating_add(size) <= MAX_STORED_BYTES { break; }
                if tx.execute("DELETE FROM clipboard_entries WHERE id=(SELECT id FROM clipboard_entries WHERE pinned=0 ORDER BY captured_at_ms,id LIMIT 1)", [])? == 0 { return Ok(false); }
            }
            tx.execute("INSERT INTO clipboard_entries(text,captured_at_ms,kind,payload,mime_type,byte_size,width,height,file_count) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)", params![text,at,kind.as_str(),bytes,mime_type,size,width,height,file_count])?;
            Ok(true)
        })?;
        self.capture_notice = (!saved).then(|| {
            "Pinned history fills the storage limit. Unpin or delete entries to capture more."
                .into()
        });
        Ok(())
    }

    #[cfg(test)]
    fn search(
        &mut self,
        query: &str,
        limit: usize,
        at: u64,
    ) -> Result<Vec<ClipboardHistoryEntry>, String> {
        if !self.enabled {
            return Err("Clipboard history is disabled.".to_string());
        }
        self.search_kind(query, limit, at, None)
    }
    fn search_kind(
        &mut self,
        query: &str,
        limit: usize,
        at: u64,
        kind: Option<ClipboardKind>,
    ) -> Result<Vec<ClipboardHistoryEntry>, String> {
        if !self.enabled {
            return Err("Clipboard history is disabled.".into());
        }
        self.prune(at)?;
        let mut statement = self.db()?.prepare(&format!("SELECT {ENTRY_COLUMNS} FROM clipboard_entries WHERE (?1 IS NULL OR kind=?1) ORDER BY pinned DESC,captured_at_ms DESC,id DESC")).map_err(|_| STORAGE_ERROR.to_string())?;
        let limit = limit.min(HISTORY_CAPACITY);
        if limit == 0 {
            return Ok(Vec::new());
        }
        let entries = statement
            .query_map([kind.map(ClipboardKind::as_str)], entry_from_row)
            .map_err(|_| STORAGE_ERROR.to_string())?;
        let needle = query.trim().to_lowercase();
        let mut matches = Vec::with_capacity(limit);
        for entry in entries {
            let entry = entry.map_err(|_| STORAGE_ERROR.to_string())?;
            if needle.is_empty() || entry.text.to_lowercase().contains(&needle) {
                // Search uses stored metadata only, even for missing or unmounted files.
                matches.push(entry);
                if matches.len() == limit {
                    break;
                }
            }
        }
        Ok(matches)
    }

    fn text_for_id(&mut self, id: u64) -> Result<String, String> {
        match self.payload_for_id(id)? {
            ClipboardPayload::Text(text) => Ok(text),
            _ => Err("Only text clipboard entries can be saved as snippets.".into()),
        }
    }
    fn payload_for_id(&mut self, id: u64) -> Result<ClipboardPayload, String> {
        if !self.enabled {
            return Err("Clipboard history is disabled.".into());
        }
        self.prune(now_ms())?;
        let entry = self
            .db()?
            .query_row(
                &format!("SELECT {ENTRY_COLUMNS} FROM clipboard_entries WHERE id=?1"),
                [id],
                entry_from_row,
            )
            .optional()
            .map_err(|_| STORAGE_ERROR)?
            .ok_or("That clipboard history entry no longer exists.")?;
        if entry.kind == ClipboardKind::Text {
            return Ok(ClipboardPayload::Text(entry.text));
        }
        let bytes: Vec<u8> = self
            .db()?
            .query_row(
                "SELECT payload FROM clipboard_entries WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .map_err(|_| STORAGE_ERROR)?;
        match entry.kind {
            ClipboardKind::Image => Ok(ClipboardPayload::Image {
                bytes,
                mime_type: entry.mime_type.ok_or("Invalid image metadata.")?,
                width: entry.width.ok_or("Invalid image metadata.")?,
                height: entry.height.ok_or("Invalid image metadata.")?,
            }),
            ClipboardKind::Files => {
                let urls = serde_json::from_slice::<Vec<String>>(&bytes)
                    .map_err(|_| "Invalid file references.")?;
                parse_file_references(&urls)?;
                Ok(ClipboardPayload::Files(urls))
            }
            ClipboardKind::Text => unreachable!(),
        }
    }

    fn set_enabled(&mut self, enabled: bool) -> Result<bool, String> {
        self.capture_notice = None;
        self.generation = self.generation.wrapping_add(1);
        if !enabled {
            self.enabled = false;
        } // Stop capture even when the subsequent disk write fails.
        let result = self.transaction(|tx| {
            tx.execute(
                "UPDATE clipboard_settings SET enabled=?1 WHERE id=1",
                [enabled],
            )?;
            if !enabled {
                tx.execute("DELETE FROM clipboard_entries", [])?;
            }
            Ok(())
        });
        if let Err(error) = result {
            if !enabled {
                let error = "History capture stopped, but saved entries could not be deleted. Retry disabling before restarting Prism.".to_string();
                self.persistence_error = Some(error.clone());
                return Err(error);
            }
            return Err(error);
        }
        self.enabled = enabled;
        Ok(enabled)
    }

    fn clear(&mut self) -> Result<usize, String> {
        self.capture_notice = None;
        self.generation = self.generation.wrapping_add(1);
        self.transaction(|tx| tx.execute("DELETE FROM clipboard_entries", []))
    }

    fn delete(&mut self, id: u64) -> Result<(), String> {
        self.capture_notice = None;
        self.generation = self.generation.wrapping_add(1);
        self.transaction(|tx| {
            tx.execute("DELETE FROM clipboard_entries WHERE id=?1", [id])?;
            Ok(())
        })
    }

    fn set_pinned(&mut self, id: u64, pinned: bool) -> Result<(), String> {
        if !self.enabled {
            return Err("Clipboard history is disabled.".to_string());
        }
        self.prune(now_ms())?;
        self.transaction(|tx| {
            if tx.execute(
                "UPDATE clipboard_entries SET pinned=?1 WHERE id=?2",
                params![pinned, id],
            )? == 0
            {
                return Err(rusqlite::Error::QueryReturnedNoRows);
            }
            Ok(())
        })
    }

    fn set_retention(&mut self, days: u32) -> Result<(), String> {
        if ![1, 7, 30, 90].contains(&days) {
            return Err("Choose a supported clipboard retention period.".to_string());
        }
        let cutoff = now_ms().saturating_sub(u64::from(days) * DAY_MS);
        self.transaction(|tx| {
            tx.execute(
                "UPDATE clipboard_settings SET retention_days=?1 WHERE id=1",
                [days],
            )?;
            tx.execute(
                "DELETE FROM clipboard_entries WHERE pinned=0 AND captured_at_ms < ?1",
                [cutoff],
            )?;
            Ok(())
        })?;
        self.retention_days = days;
        Ok(())
    }

    fn settings(&mut self) -> ClipboardHistorySettings {
        // Preserve failed-operation errors until that operation succeeds, rather than masking them with a read.
        let counts = self.connection.as_ref().and_then(|db| {
            db.query_row(
                "SELECT COUNT(*),COALESCE(SUM(pinned),0) FROM clipboard_entries",
                [],
                |r| Ok((r.get::<_, usize>(0)?, r.get::<_, usize>(1)?)),
            )
            .ok()
        });
        ClipboardHistorySettings {
            enabled: self.enabled,
            retention_days: if self.retention_days == 0 {
                30
            } else {
                self.retention_days
            },
            entry_count: counts.map_or(0, |c| c.0),
            pinned_count: counts.map_or(0, |c| c.1),
            capacity: HISTORY_CAPACITY,
            capture_notice: self.capture_notice.clone(),
            persistence_error: self
                .persistence_error
                .clone()
                .or_else(|| counts.is_none().then(|| UNAVAILABLE.to_string())),
        }
    }
}

#[derive(Clone, Default)]
pub struct ClipboardHistory {
    store: Arc<Mutex<HistoryStore>>,
}
impl ClipboardHistory {
    pub fn initialize(&self, path: PathBuf) -> Result<(), String> {
        let mut store = self.store.lock().map_err(|_| UNAVAILABLE.to_string())?;
        match HistoryStore::open(path) {
            Ok(initialized) => {
                *store = initialized;
                Ok(())
            }
            Err(error) => {
                store.persistence_error = Some(error.clone());
                Err(error)
            }
        }
    }
    pub fn start_monitor(&self) -> std::io::Result<()> {
        let history = self.clone();
        thread::Builder::new()
            .name("prism-clipboard-history".to_string())
            .spawn(move || history.monitor_loop())?;
        Ok(())
    }
    fn monitor_loop(self) {
        let mut last_observed = None;
        let mut last_generation = None;
        let mut ticks = 0;
        loop {
            let active = self
                .store
                .lock()
                .ok()
                .and_then(|store| store.enabled.then_some(store.generation));
            if let Some(generation) = active {
                let observed = read_capture_candidate(if last_generation == Some(generation) {
                    last_observed.as_deref()
                } else {
                    None
                });
                if let Some((revision, candidate)) = observed {
                    // Baseline on opt-in/clear/delete. Never recapture the clipboard that was just removed.
                    if last_generation == Some(generation)
                        && last_observed.as_ref() != Some(&revision)
                    {
                        if let Ok(mut store) = self.store.lock() {
                            if store.enabled && store.generation == generation {
                                match candidate {
                                    Ok(Some(payload)) => {
                                        if let Err(error) = store.record_payload(payload, now_ms())
                                        {
                                            store.capture_notice = Some(error);
                                        }
                                    }
                                    Err(notice) => store.capture_notice = Some(notice),
                                    Ok(None) => store.capture_notice = None,
                                }
                            }
                        }
                    }
                    last_observed = Some(revision);
                    last_generation = Some(generation);
                }
                ticks += 1;
                if ticks >= 90 {
                    if let Ok(mut store) = self.store.lock() {
                        if store.persistence_error.is_none() {
                            let _ = store.prune(now_ms());
                        }
                    }
                    ticks = 0;
                }
            } else {
                last_observed = None;
                last_generation = None;
            }
            thread::sleep(POLL_INTERVAL);
        }
    }
    fn prepare_for_action(&self, id: u64) -> Result<PreparedClipboardPayload, String> {
        self.prepare_for_action_with(id, PreparedClipboardPayload::new)
    }

    fn prepare_for_action_with(
        &self,
        id: u64,
        prepare: impl FnOnce(ClipboardPayload) -> Result<PreparedClipboardPayload, String>,
    ) -> Result<PreparedClipboardPayload, String> {
        let (payload, generation) = {
            let mut store = self.store.lock().map_err(|_| UNAVAILABLE)?;
            (store.payload_for_id(id)?, store.generation)
        };
        let prepared = prepare(payload)?;
        let mut store = self.store.lock().map_err(|_| UNAVAILABLE)?;
        if !store.enabled || store.generation != generation {
            return Err("Clipboard history changed. Select the entry again.".into());
        }
        // Retention/capacity eviction can remove an entry without changing generation.
        store.prune(now_ms())?;
        let exists: bool = store
            .db()?
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM clipboard_entries WHERE id=?1)",
                [id],
                |row| row.get(0),
            )
            .map_err(|_| STORAGE_ERROR)?;
        if !exists {
            return Err("That clipboard history entry no longer exists.".into());
        }
        Ok(prepared)
    }

    fn text_for_id(&self, id: u64) -> Result<String, String> {
        self.store
            .lock()
            .map_err(|_| UNAVAILABLE.to_string())?
            .text_for_id(id)
    }
}

// Read board AND every item privacy marker before any data, then reject torn reads.
#[cfg(target_os = "macos")]
fn read_capture_candidate(
    previous: Option<&str>,
) -> Option<(String, Result<Option<ClipboardPayload>, String>)> {
    use objc2::rc::autoreleasepool;
    use objc2_app_kit::NSPasteboard;
    use objc2_foundation::NSString;
    autoreleasepool(|_| {
        let board = NSPasteboard::generalPasteboard();
        let revision = board.changeCount();
        let revision_text = revision.to_string();
        // Baseline without materializing content; unchanged images are never re-read every poll.
        if previous.is_none() || previous == Some(revision_text.as_str()) {
            return Some((revision_text, Ok(None)));
        }
        let types = board.types()?;
        let items = board.pasteboardItems()?;
        if types
            .iter()
            .any(|t| is_private_clipboard_type(&t.to_string()))
            || items.iter().any(|item| {
                item.types()
                    .iter()
                    .any(|t| is_private_clipboard_type(&t.to_string()))
            })
        {
            return Some((revision_text, Ok(None)));
        }
        let candidate = (|| -> Result<Option<ClipboardPayload>, String> {
            let file_type = NSString::from_str("public.file-url");
            let has_files = items.iter().any(|item| {
                item.types()
                    .iter()
                    .any(|t| t.to_string() == "public.file-url")
            });
            if has_files {
                if items.len() > MAX_FILE_REFERENCES {
                    return Err("Too many file references. Clipboard history supports up to 64 files per entry.".into());
                }
                let mut urls = Vec::with_capacity(items.len());
                let mut size = 0;
                for item in items.iter() {
                    // Reject mixed multi-item payloads rather than silently dropping original items.
                    let data = item.dataForType(&file_type).ok_or("Mixed clipboard items are unsupported. Copy files together to save references.")?;
                    size += data.len();
                    if size > MAX_REFERENCE_BYTES {
                        return Err("File references exceed the clipboard size limit.".into());
                    }
                    let value = std::str::from_utf8(unsafe { data.as_bytes_unchecked() })
                        .map_err(|_| "Invalid file reference.")?
                        .to_owned();
                    urls.push(value);
                }
                validate_file_references(&urls)?;
                return Ok(Some(ClipboardPayload::Files(urls)));
            }
            if items.len() > 1 {
                return Err("Multiple non-file clipboard items are unsupported. Copy one text or image item.".into());
            }
            for (uti, mime) in [
                ("public.png", "image/png"),
                ("public.jpeg", "image/jpeg"),
                ("org.webmproject.webp", "image/webp"),
                ("public.tiff", "image/tiff"),
            ] {
                let kind = NSString::from_str(uti);
                if types.iter().any(|t| t.to_string() == uti) {
                    let data = board
                        .dataForType(&kind)
                        .ok_or("Image clipboard data is unavailable.")?;
                    if data.len() > image_input_limit(mime) {
                        return Err("Image exceeds the clipboard size limit.".into());
                    }
                    let bytes = unsafe { data.as_bytes_unchecked() }.to_vec();
                    return image_payload(bytes, mime).map(Some);
                }
            }
            if types.iter().any(|t| {
                matches!(
                    t.to_string().as_str(),
                    "public.heic"
                        | "com.compuserve.gif"
                        | "public.file-url"
                        | "NSFilenamesPboardType"
                )
            }) {
                return Err("This clipboard format is unsupported. Copy PNG, JPEG, WebP, plain text, or local files.".into());
            }
            // Do not materialize arbitrary-size plain text via arboard before checking its data length.
            let text_type = NSString::from_str("public.utf8-plain-text");
            if let Some(data) = board.dataForType(&text_type) {
                if data.len() > MAX_TEXT_BYTES {
                    return Err("Text exceeds the 128 KB clipboard history limit.".into());
                }
                let text = std::str::from_utf8(unsafe { data.as_bytes_unchecked() })
                    .map_err(|_| "Clipboard text is not valid UTF-8.")?
                    .to_owned();
                return Ok(should_capture(&text).then_some(ClipboardPayload::Text(text)));
            }
            Err("This clipboard format is unsupported. Copy PNG, JPEG, WebP, plain text, or local files.".into())
        })();
        (revision == board.changeCount()).then_some((revision_text, candidate))
    })
}
#[cfg(target_os = "macos")]
fn image_input_limit(mime_type: &str) -> usize {
    if mime_type == "image/tiff" {
        MAX_TIFF_INPUT_BYTES
    } else {
        MAX_IMAGE_BYTES
    }
}
#[cfg(target_os = "macos")]
fn image_payload(bytes: Vec<u8>, mime_type: &str) -> Result<ClipboardPayload, String> {
    use image::{ImageFormat, ImageReader};
    if bytes.is_empty() || bytes.len() > image_input_limit(mime_type) {
        return Err("Image exceeds the clipboard size limit.".into());
    }
    let format = match mime_type {
        "image/png" => ImageFormat::Png,
        "image/jpeg" => ImageFormat::Jpeg,
        "image/webp" => ImageFormat::WebP,
        "image/tiff" => ImageFormat::Tiff,
        _ => return Err("Unsupported clipboard image format.".into()),
    };
    let mut header = ImageReader::with_format(std::io::Cursor::new(&bytes), format);
    let mut header_limits = image::Limits::default();
    header_limits.max_image_width = Some(MAX_IMAGE_DIMENSION);
    header_limits.max_image_height = Some(MAX_IMAGE_DIMENSION);
    header_limits.max_alloc = Some(128 * 1024 * 1024);
    header.limits(header_limits);
    let (width, height) = header
        .into_dimensions()
        .map_err(|_| "Clipboard image is invalid or unsupported.")?;
    if !valid_dimensions(width, height) {
        return Err(
            "Image exceeds 8,192 pixels per side or 16 megapixels. Copy a smaller image.".into(),
        );
    }
    // Validate with decoder bounds before storage. TIFF is normalized for compact storage and reuse.
    let mut reader = ImageReader::with_format(std::io::Cursor::new(&bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_DIMENSION);
    limits.max_image_height = Some(MAX_IMAGE_DIMENSION);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let decoded = reader
        .decode()
        .map_err(|_| "Clipboard image is invalid or exceeds decoder limits.")?;
    let (bytes, mime_type) = if format == ImageFormat::Tiff {
        let mut output = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(decoded.into_rgba8())
            .write_to(&mut output, ImageFormat::Png)
            .map_err(|_| "Clipboard image is invalid or unsupported.")?;
        let png = output.into_inner();
        if png.len() > MAX_IMAGE_BYTES {
            return Err("Image exceeds 8 MB. Copy a smaller image to save it in history.".into());
        }
        (png, "image/png")
    } else {
        (bytes, mime_type)
    };
    Ok(ClipboardPayload::Image {
        bytes,
        mime_type: mime_type.into(),
        width,
        height,
    })
}
#[cfg(not(target_os = "macos"))]
#[path = "clipboard_portable.rs"]
mod portable;
#[cfg(not(target_os = "macos"))]
fn read_capture_candidate(previous: Option<&str>) -> Option<(String, Result<Option<ClipboardPayload>, String>)> {
    portable::capture(previous)
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn clipboard_matches(prepared: &PreparedClipboardPayload) -> bool {
    portable::matches(&prepared.0)
}

/// Called only by explicit copy, or after paste target validation on the main thread.
/// A successful macOS write acknowledges the exact pasteboard revision to guard before Cmd+V.
/// Non-macOS explicit copy has no revision guard and returns None.
pub(crate) fn write_prepared_clipboard_payload(
    prepared: PreparedClipboardPayload,
) -> Result<Option<isize>, String> {
    let PreparedClipboardPayload(payload) = prepared;
    #[cfg(target_os = "macos")]
    {
        use objc2::{rc::autoreleasepool, runtime::ProtocolObject};
        use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardWriting};
        use objc2_foundation::{NSArray, NSData, NSString};
        autoreleasepool(|_| {
            let mut objects = Vec::new();
            match payload {
                ClipboardPayload::Text(text) => {
                    let item = NSPasteboardItem::new();
                    if !item.setString_forType(
                        &NSString::from_str(&text),
                        &NSString::from_str("public.utf8-plain-text"),
                    ) {
                        return Err("Prism could not prepare clipboard text.".into());
                    }
                    objects.push(ProtocolObject::<dyn NSPasteboardWriting>::from_retained(
                        item,
                    ));
                }
                ClipboardPayload::Image {
                    bytes,
                    mime_type,
                    width,
                    height,
                } => {
                    if bytes.len() > MAX_IMAGE_BYTES || !valid_dimensions(width, height) {
                        return Err("Stored image exceeds supported limits.".into());
                    }
                    let uti = match mime_type.as_str() {
                        "image/png" => "public.png",
                        "image/jpeg" => "public.jpeg",
                        "image/webp" => "org.webmproject.webp",
                        _ => return Err("Unsupported clipboard image format.".into()),
                    };
                    let item = NSPasteboardItem::new();
                    if !item.setData_forType(&NSData::with_bytes(&bytes), &NSString::from_str(uti))
                    {
                        return Err("Prism could not prepare the clipboard image.".into());
                    }
                    objects.push(ProtocolObject::<dyn NSPasteboardWriting>::from_retained(
                        item,
                    ));
                }
                ClipboardPayload::Files(urls) => {
                    // Availability was checked before preparation, outside the history lock.
                    for url in urls {
                        let item = NSPasteboardItem::new();
                        if !item.setString_forType(
                            &NSString::from_str(&url),
                            &NSString::from_str("public.file-url"),
                        ) {
                            return Err("Prism could not prepare file references.".into());
                        }
                        objects.push(ProtocolObject::<dyn NSPasteboardWriting>::from_retained(
                            item,
                        ));
                    }
                }
            }
            let board = NSPasteboard::generalPasteboard();
            board.clearContents();
            if !board.writeObjects(&NSArray::from_retained_slice(&objects)) {
                return Err("Prism could not copy that history entry.".into());
            }
            Ok(Some(board.changeCount()))
        })
    }
    #[cfg(not(target_os = "macos"))]
    { portable::write(payload) }

}
fn is_private_clipboard_type(kind: &str) -> bool {
    let kind = kind.to_ascii_lowercase();
    matches!(
        kind.as_str(),
        "org.nspasteboard.concealedtype"
            | "org.nspasteboard.transienttype"
            | "org.nspasteboard.autogeneratedtype"
            | "org.nspasteboard.private"
            | "org.nspasteboard.privatetype"
            | "com.apple.is-remote-clipboard"
            | "de.petermaurer.transient-pasteboard-type"
            | "com.typeit4me.clipping"
            | "com.agilebits.onepassword"
    ) || kind.contains("concealed")
        || kind.contains("transient")
        || kind.ends_with(".private")
        || kind.ends_with(".privatetype")
}

#[tauri::command]
pub fn get_clipboard_history_enabled(history: State<'_, ClipboardHistory>) -> bool {
    history.store.lock().is_ok_and(|store| store.enabled)
}
#[tauri::command]
pub fn set_clipboard_history_enabled(
    history: State<'_, ClipboardHistory>,
    enabled: bool,
) -> Result<bool, String> {
    history
        .store
        .lock()
        .map_err(|_| UNAVAILABLE.to_string())?
        .set_enabled(enabled)
}
#[tauri::command]
pub fn get_clipboard_history_settings(
    history: State<'_, ClipboardHistory>,
) -> Result<ClipboardHistorySettings, String> {
    Ok(history
        .store
        .lock()
        .map_err(|_| UNAVAILABLE.to_string())?
        .settings())
}
#[tauri::command]
pub fn set_clipboard_history_retention(
    history: State<'_, ClipboardHistory>,
    retention_days: u32,
) -> Result<ClipboardHistorySettings, String> {
    let mut store = history.store.lock().map_err(|_| UNAVAILABLE.to_string())?;
    store.set_retention(retention_days)?;
    Ok(store.settings())
}
#[tauri::command]
pub fn set_clipboard_history_entry_pinned(
    history: State<'_, ClipboardHistory>,
    id: u64,
    pinned: bool,
) -> Result<(), String> {
    history
        .store
        .lock()
        .map_err(|_| UNAVAILABLE.to_string())?
        .set_pinned(id, pinned)
}
#[tauri::command]
pub fn get_clipboard_history_entry_text(
    history: State<'_, ClipboardHistory>,
    id: u64,
) -> Result<String, String> {
    history.text_for_id(id)
}
#[tauri::command]
pub fn search_clipboard_history(
    history: State<'_, ClipboardHistory>,
    query: String,
    limit: usize,
    kind: Option<ClipboardKind>,
) -> Result<Vec<ClipboardHistorySearchResult>, String> {
    Ok(history
        .store
        .lock()
        .map_err(|_| UNAVAILABLE.to_string())?
        .search_kind(&query, limit, now_ms(), kind)?
        .into_iter()
        .map(|mut entry| {
            entry.text = display_preview(&entry.text);
            entry
        })
        .collect())
}
/// Selected-entry only: never ship original image payloads to a search list.
#[tauri::command]
pub async fn get_clipboard_history_entry_preview(
    history: State<'_, ClipboardHistory>,
    id: u64,
) -> Result<String, String> {
    let permit = PREVIEW_PERMIT
        .try_acquire()
        .map_err(|_| "Image preview is busy. Retry in a moment.".to_string())?;
    let history = history.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        let (payload, generation) = {
            let mut store = history.store.lock().map_err(|_| UNAVAILABLE)?;
            (store.payload_for_id(id)?, store.generation)
        };
        let preview = image_preview(payload)?;
        // A disable, clear, or deletion while decoding invalidates the pending response.
        let store = history.store.lock().map_err(|_| UNAVAILABLE)?;
        if !store.enabled || store.generation != generation {
            return Err("Clipboard history changed. Select the image again.".into());
        }
        Ok(preview)
    })
    .await
    .map_err(|_| "Image preview could not be prepared.".to_string())?
}
fn image_preview(payload: ClipboardPayload) -> Result<String, String> {
    use base64::Engine;
    let ClipboardPayload::Image {
        bytes,
        mime_type,
        width,
        height,
    } = payload
    else {
        return Err("Only image entries have an image preview.".into());
    };
    if bytes.len() > MAX_IMAGE_BYTES || !valid_dimensions(width, height) {
        return Err("Stored image exceeds supported limits.".into());
    }
    let format = match mime_type.as_str() {
        "image/png" => image::ImageFormat::Png,
        "image/jpeg" => image::ImageFormat::Jpeg,
        "image/webp" => image::ImageFormat::WebP,
        _ => return Err("Unsupported clipboard image format.".into()),
    };
    let mut reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_DIMENSION);
    limits.max_image_height = Some(MAX_IMAGE_DIMENSION);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let decoded = reader
        .decode()
        .map_err(|_| "Image preview could not be prepared.")?;
    if !valid_dimensions(decoded.width(), decoded.height()) {
        return Err("Stored image exceeds supported limits.".into());
    }
    let mut output = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(decoded.thumbnail(256, 256).into_rgba8())
        .write_to(&mut output, image::ImageFormat::Png)
        .map_err(|_| "Image preview could not be prepared.")?;
    let bytes = output.into_inner();
    if bytes.len() > 384 * 1024 {
        return Err("Image preview exceeds its size limit.".into());
    }
    Ok(format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}
#[tauri::command]
pub async fn copy_clipboard_history_entry(
    history: State<'_, ClipboardHistory>,
    id: u64,
) -> Result<(), String> {
    let permit = ACTION_PREPARATION_PERMIT
        .try_acquire()
        .map_err(|_| "Clipboard preparation is busy. Retry in a moment.".to_string())?;
    let history = history.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        let prepared = history.prepare_for_action(id)?;
        write_prepared_clipboard_payload(prepared).map(|_| ())
    })
    .await
    .map_err(|_| "Clipboard entry could not be prepared.".to_string())?
}
#[tauri::command]
pub fn delete_clipboard_history_entry(
    history: State<'_, ClipboardHistory>,
    id: u64,
) -> Result<(), String> {
    history
        .store
        .lock()
        .map_err(|_| UNAVAILABLE.to_string())?
        .delete(id)
}
#[tauri::command]
pub async fn paste_clipboard_history_entry(
    app: tauri::AppHandle,
    history: State<'_, ClipboardHistory>,
    id: u64,
) -> Result<(), String> {
    let guard = crate::paste::PasteGuard::acquire()?;
    let permit = ACTION_PREPARATION_PERMIT
        .try_acquire()
        .map_err(|_| "Clipboard preparation is busy. Retry in a moment.".to_string())?;
    let history = history.inner().clone();
    let prepared = tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        history.prepare_for_action(id)
    })
    .await
    .map_err(|_| "Clipboard entry could not be prepared.".to_string())??;
    crate::paste::paste_prepared_payload(app, prepared, guard).await
}
#[tauri::command]
pub fn clear_clipboard_history(history: State<'_, ClipboardHistory>) -> Result<usize, String> {
    history
        .store
        .lock()
        .map_err(|_| UNAVAILABLE.to_string())?
        .clear()
}
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn display_preview(text: &str) -> String {
    let mut characters = text.chars();
    let mut preview: String = characters
        .by_ref()
        .take(SEARCH_PREVIEW_CHARACTERS)
        .collect();
    if characters.next().is_some() {
        preview.push('…');
    }
    preview
}

fn should_capture(text: &str) -> bool {
    let trimmed = text.trim();
    !trimmed.is_empty() && text.len() <= MAX_TEXT_BYTES && !looks_like_sensitive_text(trimmed)
}

fn looks_like_sensitive_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let explicit_markers = [
        "password=",
        "password:",
        "passwd=",
        "api_key=",
        "api-key:",
        "client_secret=",
        "client-secret:",
        "access_token=",
        "refresh_token=",
        "authorization: bearer ",
    ];
    if explicit_markers.iter().any(|marker| lower.contains(marker)) {
        return true;
    }
    if lower.starts_with("-----begin ") && lower.contains("private key-----") {
        return true;
    }

    let compact = text.trim();
    if [
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "github_pat_",
        "sk-",
        "xoxb-",
        "xoxp-",
    ]
    .iter()
    .any(|prefix| compact.starts_with(prefix))
    {
        return true;
    }

    if compact.starts_with("AKIA")
        && compact.len() == 20
        && compact
            .chars()
            .all(|character| character.is_ascii_alphanumeric())
    {
        return true;
    }

    let jwt_parts: Vec<&str> = compact.split('.').collect();
    jwt_parts.len() == 3
        && jwt_parts
            .iter()
            .all(|part| part.len() >= 8 && part.chars().all(is_base64_url_character))
}

fn is_base64_url_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '=')
}

#[cfg(test)]
mod tests {
    use super::*;
    fn store() -> HistoryStore {
        let mut store =
            HistoryStore::from_connection(Connection::open_in_memory().unwrap()).unwrap();
        store.set_enabled(true).unwrap();
        store
    }
    struct TestDatabase(PathBuf);
    impl TestDatabase {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                    "prism-clipboard-test-{}-{}.sqlite3",
                    std::process::id(),
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                )))
        }
    }
    impl Drop for TestDatabase {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn unavailable_storage_never_falls_back_to_volatile_capture() {
        let history = ClipboardHistory::default();
        let directory = std::env::temp_dir();
        assert!(history.initialize(directory).is_err());
        let mut store = history.store.lock().unwrap();
        assert!(!store.enabled);
        assert!(store.set_enabled(true).is_err());
        assert!(!store.enabled);
        assert!(store.settings().persistence_error.is_some());
        assert!(store.search("", 10, now_ms()).is_err());
    }
    #[test]
    fn opt_in_pins_text_and_retention_survive_restart() {
        let path = TestDatabase::new();
        let id;
        {
            let mut store = HistoryStore::open(path.0.clone()).unwrap();
            assert!(!store.enabled);
            store
                .record("must not persist before consent".into(), now_ms())
                .unwrap();
            assert_eq!(store.settings().entry_count, 0);
            store.set_enabled(true).unwrap();
            store.set_retention(7).unwrap();
            store.record("지속되는 메모".into(), now_ms()).unwrap();
            id = store.search("", 1, now_ms()).unwrap()[0].id;
            store.set_pinned(id, true).unwrap();
        }
        let mut reopened = HistoryStore::open(path.0.clone()).unwrap();
        assert!(reopened.enabled);
        assert_eq!(reopened.retention_days, 7);
        assert_eq!(reopened.text_for_id(id).unwrap(), "지속되는 메모");
        assert!(reopened.search("", 1, now_ms()).unwrap()[0].pinned);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path.0).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn bounded_deduplication_preserves_pin_and_stable_identity() {
        let mut store = store();
        let at = now_ms();
        store.record("pinned".into(), at).unwrap();
        let id = store.search("", 1, at).unwrap()[0].id;
        store.set_pinned(id, true).unwrap();
        for index in 0..(HISTORY_CAPACITY + 5) {
            store
                .record(format!("entry {index}"), at + index as u64)
                .unwrap();
        }
        store.record("pinned".into(), at + 9999).unwrap();
        let entries = store.search("", HISTORY_CAPACITY + 100, at + 9999).unwrap();
        assert_eq!(entries.len(), HISTORY_CAPACITY);
        assert_eq!(entries[0].id, id);
        assert!(entries[0].pinned);
        assert_eq!(
            entries
                .iter()
                .filter(|entry| entry.text == "pinned")
                .count(),
            1
        );
        assert!(!entries.iter().any(|entry| entry.text == "entry 0"));
    }

    #[test]
    fn all_pinned_capacity_rejects_new_content_without_evicting_pins() {
        let mut store = store();
        let at = now_ms();
        for index in 0..HISTORY_CAPACITY {
            store.record(format!("pin {index}"), at).unwrap();
        }
        store
            .db()
            .unwrap()
            .execute("UPDATE clipboard_entries SET pinned=1", [])
            .unwrap();
        store.record("overflow".into(), at + 1).unwrap();
        assert_eq!(store.settings().entry_count, HISTORY_CAPACITY);
        assert_eq!(store.settings().pinned_count, HISTORY_CAPACITY);
        assert!(store.search("overflow", 1, at + 1).unwrap().is_empty());
    }

    #[test]
    fn shortening_retention_expires_unpinned_but_preserves_pins() {
        let mut store = store();
        let at = now_ms();
        store.record("old pin".into(), at - 2 * DAY_MS).unwrap();
        let id = store.search("old pin", 1, at).unwrap()[0].id;
        store.set_pinned(id, true).unwrap();
        store
            .record("old unpinned".into(), at - 2 * DAY_MS)
            .unwrap();
        store.record("recent".into(), at).unwrap();
        store.set_retention(1).unwrap();
        let entries = store.search("", 100, at).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries.iter().any(|entry| entry.id == id));
        assert!(!entries.iter().any(|entry| entry.text == "old unpinned"));
        store.set_pinned(id, false).unwrap();
        assert!(store.text_for_id(id).is_err());
        assert!(store.set_retention(365).is_err());
        assert_eq!(store.retention_days, 1);
    }

    #[test]
    fn restart_prunes_expired_unpinned_entries() {
        let path = TestDatabase::new();
        {
            let mut store = HistoryStore::open(path.0.clone()).unwrap();
            store.set_enabled(true).unwrap();
            store
                .record("expired".into(), now_ms() - 31 * DAY_MS)
                .unwrap();
        }
        let mut store = HistoryStore::open(path.0.clone()).unwrap();
        assert_eq!(store.settings().entry_count, 0);
    }

    #[test]
    fn clear_and_disable_remove_pins_durably_but_only_disable_turns_capture_off() {
        let path = TestDatabase::new();
        let mut store = HistoryStore::open(path.0.clone()).unwrap();
        store.set_enabled(true).unwrap();
        store.record("pin".into(), now_ms()).unwrap();
        let first_id = store.search("", 1, now_ms()).unwrap()[0].id;
        store.set_pinned(first_id, true).unwrap();
        assert_eq!(store.clear().unwrap(), 1);
        assert!(store.enabled);
        store.record("new text".into(), now_ms()).unwrap();
        let second_id = store.search("", 1, now_ms()).unwrap()[0].id;
        assert!(second_id > first_id);
        assert!(store.text_for_id(first_id).is_err());
        store.set_enabled(false).unwrap();
        assert!(store.text_for_id(second_id).is_err());
        drop(store);
        let mut reopened = HistoryStore::open(path.0.clone()).unwrap();
        assert!(!reopened.enabled);
        assert_eq!(reopened.settings().entry_count, 0);
    }

    #[test]
    fn delete_is_durable_idempotent_and_does_not_delete_other_entries() {
        let path = TestDatabase::new();
        let mut store = HistoryStore::open(path.0.clone()).unwrap();
        store.set_enabled(true).unwrap();
        store.record("delete me".into(), now_ms()).unwrap();
        let id = store.search("", 1, now_ms()).unwrap()[0].id;
        store.record("keep me".into(), now_ms()).unwrap();
        store.delete(id).unwrap();
        store.delete(id).unwrap();
        drop(store);
        let mut reopened = HistoryStore::open(path.0.clone()).unwrap();
        assert!(reopened.text_for_id(id).is_err());
        assert_eq!(
            reopened.search("", 100, now_ms()).unwrap()[0].text,
            "keep me"
        );
    }

    #[test]
    fn write_failure_is_visible_and_failed_delete_rolls_back() {
        let mut store = store();
        store
            .record("keep after failed deletion".into(), now_ms())
            .unwrap();
        store
            .db()
            .unwrap()
            .execute_batch("PRAGMA query_only=ON")
            .unwrap();
        assert!(store.clear().is_err());
        assert_eq!(store.settings().entry_count, 1);
        assert!(store.settings().persistence_error.is_some());
        assert!(store.set_enabled(false).is_err());
        assert!(!store.enabled);
        store
            .db()
            .unwrap()
            .execute_batch("PRAGMA query_only=OFF")
            .unwrap();
        store.set_enabled(false).unwrap();
        assert_eq!(store.settings().entry_count, 0);
        assert!(store.settings().persistence_error.is_none());
    }

    #[test]
    fn credentials_privacy_markers_and_size_limits_are_rejected() {
        for text in [
            "-----BEGIN PRIVATE KEY-----\nabc",
            "password=hunter2",
            "ghp_abcdefghijklmnopqrstuvwxyz",
            "eyJhbGciOiJIUzI1NiJ9.abcdefghijk.abcdefghijklmnop",
        ] {
            assert!(!should_capture(text));
        }
        assert!(!should_capture(&"a".repeat(MAX_TEXT_BYTES + 1)));
        assert!(should_capture("A normal clipboard note"));
        for kind in [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
            "org.nspasteboard.private",
            "de.petermaurer.TransientPasteboardType",
            "com.agilebits.onepassword",
        ] {
            assert!(is_private_clipboard_type(kind), "{kind}");
        }
        assert!(!is_private_clipboard_type("public.utf8-plain-text"));
    }

    #[test]
    fn full_text_is_preserved_while_preview_is_utf8_safe_and_search_is_case_insensitive() {
        let mut store = store();
        let text = format!("Prism {} tail", "클립".repeat(300));
        store.record(text.clone(), now_ms()).unwrap();
        let entry = store.search("prism", 1, now_ms()).unwrap().remove(0);
        assert_eq!(store.text_for_id(entry.id).unwrap(), text);
        let mut preview = entry;
        preview.text = display_preview(&preview.text);
        assert_eq!(preview.text.chars().count(), SEARCH_PREVIEW_CHARACTERS + 1);
        assert!(preview.text.ends_with('…'));
        assert!(store.search("TAIL", 1, now_ms()).unwrap().len() == 1);
    }
    #[test]
    fn v1_migration_keeps_text_pins_consent_and_deleted_id_high_water() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE clipboard_settings(id INTEGER PRIMARY KEY,enabled INTEGER NOT NULL,retention_days INTEGER NOT NULL);
            INSERT INTO clipboard_settings VALUES(1,1,7);
            CREATE TABLE clipboard_entries(id INTEGER PRIMARY KEY AUTOINCREMENT,text TEXT NOT NULL UNIQUE,captured_at_ms INTEGER NOT NULL,pinned INTEGER NOT NULL DEFAULT 0);").unwrap();
        db.execute("INSERT INTO clipboard_entries(id,text,captured_at_ms,pinned) VALUES(42,'기존 메모',?1,1)", [now_ms()]).unwrap();
        db.execute(
            "INSERT INTO clipboard_entries(id,text,captured_at_ms) VALUES(900,'deleted',?1)",
            [now_ms()],
        )
        .unwrap();
        db.execute("DELETE FROM clipboard_entries WHERE id=900", [])
            .unwrap();
        let mut store = HistoryStore::from_connection(db).unwrap();
        assert!(store.enabled);
        assert_eq!(store.retention_days, 7);
        assert_eq!(store.text_for_id(42).unwrap(), "기존 메모");
        let entry = store.search("", 1, now_ms()).unwrap().remove(0);
        assert!(entry.pinned);
        assert_eq!(entry.kind, ClipboardKind::Text);
        store.record("after migration".into(), now_ms()).unwrap();
        assert!(store.search("after migration", 1, now_ms()).unwrap()[0].id > 900);
    }

    #[test]
    fn references_remain_metadata_and_missing_files_fail_reuse() {
        let file = TestDatabase::new();
        std::fs::write(&file.0, b"password=must never enter the clipboard database").unwrap();
        let url = reqwest::Url::from_file_path(&file.0).unwrap().to_string();
        let mut store = store();
        store
            .record_payload(ClipboardPayload::Files(vec![url.clone()]), now_ms())
            .unwrap();
        store.record("ordinary text".into(), now_ms()).unwrap();
        let entry = store
            .search_kind("", 10, now_ms(), Some(ClipboardKind::Files))
            .unwrap()
            .remove(0);
        assert_eq!(entry.available, None);
        assert_eq!(entry.file_count, 1);
        assert!(store.text_for_id(entry.id).is_err());
        let bytes: Vec<u8> = store
            .db()
            .unwrap()
            .query_row(
                "SELECT payload FROM clipboard_entries WHERE id=?1",
                [entry.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_slice::<Vec<String>>(&bytes).unwrap(),
            vec![url]
        );
        std::fs::remove_file(&file.0).unwrap();
        assert!(PreparedClipboardPayload::new(store.payload_for_id(entry.id).unwrap()).is_err());
        assert_eq!(
            store
                .search_kind("", 10, now_ms(), Some(ClipboardKind::Files))
                .unwrap()[0]
                .available,
            None
        );
        assert!(validate_file_references(&["https://example.com/file".into()]).is_err());
        assert!(validate_file_references(&["file://remote/private/file".into()]).is_err());
        assert!(
            validate_file_references(&vec!["file:///tmp".into(); MAX_FILE_REFERENCES + 1]).is_err()
        );
    }

    #[test]
    fn file_search_uses_only_metadata_and_reports_unknown_availability() {
        // This path is deliberately absent: storing/searching metadata must not stat it.
        let missing = TestDatabase::new();
        let url = reqwest::Url::from_file_path(&missing.0)
            .unwrap()
            .to_string();
        let mut store = store();
        store
            .record_payload(ClipboardPayload::Files(vec![url]), now_ms())
            .unwrap();
        store.record("plain text".into(), now_ms()).unwrap();
        let entry = store
            .search_kind(
                "prism-clipboard-test",
                1,
                now_ms(),
                Some(ClipboardKind::Files),
            )
            .unwrap()
            .remove(0);
        assert_eq!(entry.available, None);
        assert!(serde_json::to_value(&entry).unwrap()["available"].is_null());
        assert_eq!(
            store
                .search_kind("plain", 1, now_ms(), Some(ClipboardKind::Text))
                .unwrap()[0]
                .available,
            Some(true)
        );
        // Even unreadable payload bytes cannot affect the list: it never loads the payload.
        store
            .db()
            .unwrap()
            .execute(
                "UPDATE clipboard_entries SET payload=X'00' WHERE id=?1",
                [entry.id],
            )
            .unwrap();
        let listed = store
            .search_kind(
                "prism-clipboard-test",
                1,
                now_ms(),
                Some(ClipboardKind::Files),
            )
            .unwrap()
            .remove(0);
        assert_eq!(listed, entry);
        assert!(store.payload_for_id(entry.id).is_err());
    }

    #[test]
    fn action_validation_releases_lock_and_rejects_history_changes() {
        for change in 0..4 {
            let mut store = store();
            store.record("selected".into(), now_ms()).unwrap();
            let id = store.search("", 1, now_ms()).unwrap()[0].id;
            let history = ClipboardHistory {
                store: Arc::new(Mutex::new(store)),
            };
            let result = history.prepare_for_action_with(id, |payload| {
                // A slow validator must allow destructive operations to acquire the mutex.
                let mut store = history
                    .store
                    .try_lock()
                    .expect("validation held history lock");
                match change {
                    0 => {
                        store.clear().unwrap();
                    }
                    1 => {
                        store.delete(id).unwrap();
                    }
                    2 => {
                        store.set_enabled(false).unwrap();
                    }
                    _ => {
                        // Capacity/retention eviction does not increment generation.
                        store
                            .db()
                            .unwrap()
                            .execute("DELETE FROM clipboard_entries WHERE id=?1", [id])
                            .unwrap();
                    }
                }
                drop(store);
                PreparedClipboardPayload::new(payload)
            });
            assert!(result.is_err(), "stale action survived change {change}");
        }
    }

    #[test]
    fn action_validation_allows_unchanged_entry_without_holding_lock() {
        let mut store = store();
        store.record("selected".into(), now_ms()).unwrap();
        let id = store.search("", 1, now_ms()).unwrap()[0].id;
        let history = ClipboardHistory {
            store: Arc::new(Mutex::new(store)),
        };
        let result = history.prepare_for_action_with(id, |payload| {
            assert!(history.store.try_lock().is_ok());
            PreparedClipboardPayload::new(payload)
        });
        assert!(result.is_ok());
    }

    #[test]
    fn byte_budget_evicts_old_unpinned_and_never_evicts_pins() {
        let mut store = store();
        store.record("old".into(), now_ms()).unwrap();
        store
            .db()
            .unwrap()
            .execute(
                "UPDATE clipboard_entries SET byte_size=?1",
                [MAX_STORED_BYTES],
            )
            .unwrap();
        store.record("new".into(), now_ms()).unwrap();
        assert!(store.search("old", 1, now_ms()).unwrap().is_empty());
        let entry = store.search("new", 1, now_ms()).unwrap().remove(0);
        store.set_pinned(entry.id, true).unwrap();
        store
            .db()
            .unwrap()
            .execute(
                "UPDATE clipboard_entries SET byte_size=?1",
                [MAX_STORED_BYTES],
            )
            .unwrap();
        store.record("rejected".into(), now_ms()).unwrap();
        assert_eq!(store.settings().entry_count, 1);
        assert!(store.settings().capture_notice.is_some());
        assert_eq!(store.text_for_id(entry.id).unwrap(), "new");
    }

    #[test]
    fn image_bounds_reject_zero_oversize_pixels_bytes_and_unknown_formats() {
        assert!(!valid_dimensions(0, 100));
        assert!(!valid_dimensions(MAX_IMAGE_DIMENSION + 1, 1));
        assert!(!valid_dimensions(8192, 8192));
        assert!(valid_dimensions(4000, 4000));
        let payload = ClipboardPayload::Image {
            bytes: vec![0; MAX_IMAGE_BYTES + 1],
            mime_type: "image/png".into(),
            width: 1,
            height: 1,
        };
        assert!(payload.stored().is_err());
        let payload = ClipboardPayload::Image {
            bytes: vec![0],
            mime_type: "image/tiff".into(),
            width: 1,
            height: 1,
        };
        assert!(payload.stored().is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn tiff_capture_normalizes_pixels_to_png_and_reuses_existing_history_actions() {
        let original = image::RgbaImage::from_pixel(4, 3, image::Rgba([23, 97, 201, 128]));
        let mut encoded = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(original.clone())
            .write_to(&mut encoded, image::ImageFormat::Tiff)
            .unwrap();
        let payload = image_payload(encoded.into_inner(), "image/tiff").unwrap();
        let ClipboardPayload::Image {
            ref bytes,
            ref mime_type,
            width,
            height,
        } = payload
        else {
            panic!("Expected image")
        };
        assert_eq!((width, height), (4, 3));
        assert_eq!(mime_type, "image/png");
        assert_eq!(
            image::load_from_memory(bytes).unwrap().into_rgba8(),
            original
        );
        assert!(payload.stored().is_ok());
        assert!(image_preview(payload)
            .unwrap()
            .starts_with("data:image/png;base64,"));
        assert!(image_payload(vec![1, 2, 3], "image/tiff").is_err());
        assert_eq!(image_input_limit("image/png"), MAX_IMAGE_BYTES);
        assert_eq!(image_input_limit("image/tiff"), MAX_TIFF_INPUT_BYTES);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn original_images_survive_restart_deduplicate_and_are_removed_with_history() {
        let mut encoded = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgba8(2, 3)
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let bytes = encoded.into_inner();
        assert!(image_payload(vec![1, 2, 3], "image/png").is_err());
        let path = TestDatabase::new();
        let id;
        {
            let mut store = HistoryStore::open(path.0.clone()).unwrap();
            store
                .record_payload(image_payload(bytes.clone(), "image/png").unwrap(), now_ms())
                .unwrap();
            assert_eq!(store.settings().entry_count, 0);
            store.set_enabled(true).unwrap();
            store
                .record_payload(image_payload(bytes.clone(), "image/png").unwrap(), now_ms())
                .unwrap();
            id = store
                .search_kind("", 1, now_ms(), Some(ClipboardKind::Image))
                .unwrap()[0]
                .id;
            store.set_pinned(id, true).unwrap();
            store
                .record_payload(image_payload(bytes.clone(), "image/png").unwrap(), now_ms())
                .unwrap();
            assert_eq!(store.settings().entry_count, 1);
        }
        let mut store = HistoryStore::open(path.0.clone()).unwrap();
        match store.payload_for_id(id).unwrap() {
            ClipboardPayload::Image {
                bytes: original,
                width,
                height,
                ..
            } => {
                assert_eq!(original, bytes);
                assert_eq!((width, height), (2, 3));
            }
            _ => panic!("image payload lost"),
        }
        assert!(
            store
                .search_kind("", 1, now_ms(), Some(ClipboardKind::Image))
                .unwrap()[0]
                .pinned
        );
        store.clear().unwrap();
        assert!(store.payload_for_id(id).is_err());
        assert_eq!(
            store
                .db()
                .unwrap()
                .query_row(
                    "SELECT COALESCE(SUM(length(payload)),0) FROM clipboard_entries",
                    [],
                    |r| r.get::<_, usize>(0)
                )
                .unwrap(),
            0
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn selected_preview_is_a_bounded_png_and_does_not_change_original() {
        use base64::Engine;
        let mut encoded = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(1024, 512)
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let payload = image_payload(encoded.into_inner(), "image/png").unwrap();
        let preview = image_preview(payload).unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(preview.strip_prefix("data:image/png;base64,").unwrap())
            .unwrap();
        assert!(bytes.len() <= 384 * 1024);
        let image = image::load_from_memory(&bytes).unwrap();
        assert_eq!((image.width(), image.height()), (256, 128));
        assert!(image_preview(ClipboardPayload::Text("plain text".into())).is_err());
    }
}
