//! Versioned, deliberately narrow backups. Include as a child of `library`.
use super::{Entry, Favorite, Library};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    hash::{BuildHasher, Hash, Hasher},
    io::{Read, Write},
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};
use tauri::State;

const MAX_BYTES: usize = 20 * 1024 * 1024;
const REVIEW_TTL: Duration = Duration::from_secs(10 * 60);
const INVALID: &str = "This backup contains invalid data. Nothing was imported.";
const MALFORMED: &str = "This backup is malformed JSON. Nothing was imported.";
const NEWER: &str = "This backup uses a newer unsupported version. Update Prism before importing.";
const UNSUPPORTED: &str = "This backup contains unsupported fields or data. Nothing was imported.";
const STALE: &str = "The backup review expired or the library changed. Review the file again.";
const WRITE_ERROR: &str = "The backup could not be saved. The existing file was preserved.";

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Categories {
    snippets: bool,
    quicklinks: bool,
    #[serde(default)]
    path_links: bool,
    favorites: bool,
    preferences: bool,
}
impl Categories {
    fn any(&self) -> bool {
        self.snippets || self.quicklinks || self.path_links || self.favorites || self.preferences
    }
    fn includes(&self, kind: &str) -> bool {
        (kind == "snippet" && self.snippets)
            || (kind == "link" && self.quicklinks)
            || (kind == "path" && self.path_links)
    }
}

/// This allowlist is not the full SettingsPreferences contract. No consent,
/// execution configuration, hotkeys, keys, histories, or filesystem grants.
#[derive(Clone, Deserialize, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SafePreferences {
    language: String,
    theme: String,
    reduce_motion: bool,
    background_opacity: f64,
    background_blur: f64,
    show_application_icons: bool,
    command_aliases: BTreeMap<String, String>,
}
impl SafePreferences {
    fn validate(&self) -> Result<(), String> {
        if !["system", "en", "ko"].contains(&self.language.as_str())
            || !["system", "dark", "light"].contains(&self.theme.as_str())
            || !self.background_opacity.is_finite()
            || !(10.0..=100.0).contains(&self.background_opacity)
            || !self.background_blur.is_finite()
            || !(0.0..=240.0).contains(&self.background_blur)
            || self.command_aliases.len() > 1000
            || self.command_aliases.iter().any(|(id, alias)| {
                !super::valid_id(id)
                    || ["__proto__", "prototype", "constructor"].contains(&id.as_str())
                    || alias.trim().is_empty()
                    || alias.encode_utf16().count() > 80
                    || alias.chars().any(char::is_control)
            })
        {
            return Err(INVALID.into());
        }
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BackupEntry {
    id: String,
    kind: String,
    title: String,
    value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    keyword: Option<String>,
}
impl BackupEntry {
    fn entry(&self) -> Entry {
        Entry {
            id: self.id.clone(),
            kind: self.kind.clone(),
            title: self.title.clone(),
            value: self.value.clone(),
            keyword: self.keyword.clone(),
        }
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BackupFavorite {
    id: String,
    title: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    format: String,
    version: u32,
    entries: Vec<BackupEntry>,
    favorites: Vec<BackupFavorite>,
    preferences: Option<SafePreferences>,
}
impl Document {
    fn validate(&self) -> Result<(), String> {
        if self.version > 2 {
            return Err(NEWER.into());
        }
        if self.format != "prism-backup"
            || ![1, 2].contains(&self.version)
            || self.entries.len() > 1000
            || self.favorites.len() > 50
            || self.entries.iter().map(|e| e.value.len()).sum::<usize>() > 16 * 1024 * 1024
        {
            return Err(INVALID.into());
        }
        let mut ids = HashSet::new();
        for entry in &self.entries {
            if !["snippet", "link", "path"].contains(&entry.kind.as_str()) || !ids.insert(&entry.id)
            {
                return Err(INVALID.into());
            }
            super::validate_entry(&entry.entry()).map_err(|_| INVALID.to_owned())?;
        }
        let mut ids = HashSet::new();
        for favorite in &self.favorites {
            if !super::valid_id(&favorite.id)
                || favorite.title.trim().is_empty()
                || favorite.title.len() > 500
                || !ids.insert(&favorite.id)
            {
                return Err(INVALID.into());
            }
        }
        if let Some(preferences) = &self.preferences {
            preferences.validate()?;
        }
        Ok(())
    }
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    total: usize,
    added: usize,
    conflicts: usize,
    skipped: usize,
}
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    snippets: Counts,
    quicklinks: Counts,
    path_links: Counts,
    favorites: Counts,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PathReference {
    id: String,
    title: String,
    path: String,
    status: String,
    conflict: bool,
}
fn path_status(path: &str) -> String {
    // Metadata only: never enumerate/read the target, authorize a root, or grant AI access.
    match std::fs::metadata(path) {
        Ok(_) => "existing",
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => "missing",
        Err(_) => "unavailable",
    }
    .into()
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    token: String,
    summary: Summary,
    path_references: Vec<PathReference>,
    missing_favorites: Vec<BackupFavorite>,
    preferences: Option<SafePreferences>,
}
struct Prepared {
    created: Instant,
    baseline: Vec<u8>,
    entries: Vec<BackupEntry>,
    favorites: Vec<BackupFavorite>,
    summary: Summary,
    path_references: Vec<PathReference>,
    missing_favorites: Vec<BackupFavorite>,
}
#[derive(Default)]
pub struct BackupState {
    reviews: Mutex<HashMap<String, Prepared>>,
    hash: std::collections::hash_map::RandomState,
    counter: AtomicU64,
}
impl BackupState {
    fn issue(&self, prepared: Prepared) -> Result<String, String> {
        let counter = self.counter.fetch_add(1, Ordering::Relaxed);
        let mut hasher = self.hash.build_hasher();
        ("backup-review", counter).hash(&mut hasher);
        let token = format!("backup-{counter}-{:016x}", hasher.finish());
        let mut reviews = self.reviews.lock().map_err(|_| STALE)?;
        reviews.retain(|_, value| value.created.elapsed() <= REVIEW_TTL);
        // Bounded native snapshots, and only the most recent chooser review is usable.
        reviews.clear();
        reviews.insert(token.clone(), prepared);
        Ok(token)
    }
    fn take(&self, token: &str) -> Result<Prepared, String> {
        self.reviews
            .lock()
            .map_err(|_| STALE)?
            .remove(token)
            .ok_or_else(|| STALE.into())
    }
}

fn parse(bytes: &[u8]) -> Result<Document, String> {
    if bytes.len() > MAX_BYTES {
        return Err("Backup files must be 20 MB or smaller.".into());
    }
    #[derive(Deserialize)]
    struct Header {
        version: u64,
    }
    let header: Header = serde_json::from_slice(bytes).map_err(|error| {
        if error.is_syntax() || error.is_eof() {
            MALFORMED
        } else {
            INVALID
        }
    })?;
    if header.version > 2 {
        return Err(NEWER.into());
    }
    let document: Document = serde_json::from_slice(bytes).map_err(|error| {
        if error.to_string().contains("unknown field") {
            UNSUPPORTED
        } else {
            INVALID
        }
    })?;
    document.validate()?;
    Ok(document)
}
fn baseline(db: &Connection) -> Result<Vec<u8>, String> {
    // Include all library data, including roots/path entries; a concurrent change
    // invalidates review instead of silently changing the reviewed merge result.
    serde_json::to_vec(&super::read(db)?).map_err(|_| INVALID.into())
}
fn prepare(
    db: &Connection,
    document: Document,
    categories: &Categories,
) -> Result<(Prepared, Option<SafePreferences>), String> {
    document.validate()?;
    if !categories.any() {
        return Err("Select at least one backup category.".into());
    }
    let current = super::read(db)?;
    let mut ids: HashSet<String> = current
        .entries
        .iter()
        .map(|entry| entry.id.clone())
        .collect();
    let mut keywords: HashSet<String> = current
        .entries
        .iter()
        .filter_map(|entry| super::normalized_keyword(entry).map(str::to_owned))
        .collect();
    let mut prepared = Prepared {
        created: Instant::now(),
        baseline: baseline(db)?,
        entries: vec![],
        favorites: vec![],
        summary: Summary::default(),
        path_references: vec![],
        missing_favorites: vec![],
    };
    for entry in document
        .entries
        .into_iter()
        .filter(|entry| categories.includes(&entry.kind))
    {
        if entry.kind == "path" {
            prepared.path_references.push(PathReference {
                id: entry.id.clone(),
                title: entry.title.clone(),
                path: entry.value.clone(),
                status: path_status(&entry.value),
                conflict: ids.contains(&entry.id),
            });
        }
        let counts = match entry.kind.as_str() {
            "snippet" => &mut prepared.summary.snippets,
            "path" => &mut prepared.summary.path_links,
            _ => &mut prepared.summary.quicklinks,
        };
        counts.total += 1;
        if !ids.insert(entry.id.clone()) {
            counts.conflicts += 1;
        } else {
            if let Some(keyword) = entry
                .keyword
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                if !keywords.insert(keyword.to_owned()) {
                    return Err(
                        "A snippet keyword conflicts with another snippet. Nothing was imported."
                            .into(),
                    );
                }
            }
            counts.added += 1;
            prepared.entries.push(entry);
        }
    }
    if current.entries.len() + prepared.entries.len() > 1000
        || current.entries.iter().map(|e| e.value.len()).sum::<usize>()
            + prepared
                .entries
                .iter()
                .map(|e| e.value.len())
                .sum::<usize>()
            > 16 * 1024 * 1024
    {
        return Err("The merged library exceeds its storage limit.".into());
    }
    let mut favorites: HashSet<String> = current
        .favorites
        .iter()
        .map(|favorite| favorite.id.clone())
        .collect();
    for favorite in document
        .favorites
        .into_iter()
        .filter(|_| categories.favorites)
    {
        let counts = &mut prepared.summary.favorites;
        counts.total += 1;
        if favorites.contains(&favorite.id) {
            counts.conflicts += 1;
        } else if favorite
            .id
            .strip_prefix("library:")
            .is_some_and(|id| !ids.contains(id))
        {
            counts.skipped += 1;
            prepared.missing_favorites.push(favorite);
        } else {
            favorites.insert(favorite.id.clone());
            counts.added += 1;
            prepared.favorites.push(favorite);
        }
    }
    if favorites.len() > 50 {
        return Err("The merged library exceeds its storage limit.".into());
    }
    let preferences = if categories.preferences {
        document.preferences
    } else {
        None
    };
    Ok((prepared, preferences))
}
fn apply(db: &mut Connection, prepared: Prepared) -> Result<Summary, String> {
    if prepared.created.elapsed() > REVIEW_TTL {
        return Err(STALE.into());
    }
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "The library could not be restored. Review the file and try again.")?;
    if baseline(&tx)? != prepared.baseline {
        return Err(STALE.into());
    }
    for entry in &prepared.entries {
        super::save(&tx, &entry.entry())
            .map_err(|_| "The library could not be restored. Review the file and try again.")?;
    }
    for favorite in &prepared.favorites {
        tx.execute("INSERT INTO favorites(id,title,position) VALUES(?1,?2,(SELECT COALESCE(MAX(position),0)+1 FROM favorites))", params![favorite.id, favorite.title])
            .map_err(|_| "The library could not be restored. Review the file and try again.")?;
    }
    tx.commit()
        .map_err(|_| "The library could not be restored. Review the file and try again.")?;
    Ok(prepared.summary)
}

fn read_file(path: &Path) -> Result<Vec<u8>, String> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|_| "The backup file could not be read.")?;
    let metadata = file
        .metadata()
        .map_err(|_| "The backup file could not be read.")?;
    if !metadata.is_file() {
        return Err(INVALID.into());
    }
    if metadata.len() > MAX_BYTES as u64 {
        return Err("Backup files must be 20 MB or smaller.".into());
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "The backup file could not be read.")?;
    if bytes.len() > MAX_BYTES {
        return Err("Backup files must be 20 MB or smaller.".into());
    }
    Ok(bytes)
}
fn write_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > MAX_BYTES {
        return Err("Backup files must be 20 MB or smaller.".into());
    }
    let parent = path.parent().ok_or(WRITE_ERROR)?;
    // Exclusive sibling creation prevents overwriting another process's temp file.
    // Rename publishes only a complete, synced file and preserves the old destination on failure.
    let mut temp = None;
    for index in 0..100 {
        let candidate = parent.join(format!(".prism-backup-{}-{index}.tmp", std::process::id()));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&candidate) {
            Ok(file) => {
                temp = Some((candidate, file));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err(WRITE_ERROR.into()),
        }
    }
    let (temp_path, mut file) = temp.ok_or(WRITE_ERROR)?;
    let result = (|| {
        file.write_all(bytes).map_err(|_| WRITE_ERROR)?;
        file.sync_all().map_err(|_| WRITE_ERROR)?;
        drop(file);
        std::fs::rename(&temp_path, path).map_err(|_| WRITE_ERROR)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp_path);
    }
    result
}

#[tauri::command]
pub async fn backup_export(
    app: tauri::AppHandle,
    library: State<'_, Library>,
    categories: Categories,
    preferences: Option<SafePreferences>,
) -> Result<bool, String> {
    if !categories.any() {
        return Err("Select at least one backup category.".into());
    }
    let bytes = {
        let _guard = library.lock.lock().map_err(|_| INVALID)?;
        let current = super::read(&super::db(&app)?)?;
        let entries: Vec<BackupEntry> = current
            .entries
            .into_iter()
            .filter(|entry| categories.includes(&entry.kind))
            .map(|entry| BackupEntry {
                id: entry.id,
                kind: entry.kind,
                title: entry.title,
                value: entry.value,
                keyword: entry.keyword,
            })
            .collect();
        let favorites = current
            .favorites
            .into_iter()
            .filter(|_| categories.favorites)
            .map(|favorite: Favorite| BackupFavorite {
                id: favorite.id,
                title: favorite.title,
            })
            .collect();
        let document = Document {
            format: "prism-backup".into(),
            version: 2,
            entries,
            favorites,
            preferences: if categories.preferences {
                Some(preferences.ok_or(INVALID)?)
            } else {
                None
            },
        };
        document.validate()?;
        serde_json::to_vec_pretty(&document).map_err(|_| INVALID)?
    };
    let Some(file) = rfd::AsyncFileDialog::new()
        .add_filter("Prism backup", &["json"])
        .set_file_name("prism-backup-v2.json")
        .save_file()
        .await
    else {
        return Ok(false);
    };
    let path = file.path().to_path_buf();
    tauri::async_runtime::spawn_blocking(move || write_file(&path, &bytes))
        .await
        .map_err(|_| WRITE_ERROR)??;
    Ok(true)
}
#[tauri::command]
pub async fn backup_preview_import(
    app: tauri::AppHandle,
    library: State<'_, Library>,
    state: State<'_, BackupState>,
    categories: Categories,
) -> Result<Option<Review>, String> {
    if !categories.any() {
        return Err("Select at least one backup category.".into());
    }
    let Some(file) = rfd::AsyncFileDialog::new()
        .add_filter("Prism backup", &["json"])
        .pick_file()
        .await
    else {
        return Ok(None);
    };
    let path = file.path().to_path_buf();
    let document = tauri::async_runtime::spawn_blocking(move || parse(&read_file(&path)?))
        .await
        .map_err(|_| INVALID)??;
    let _guard = library.lock.lock().map_err(|_| INVALID)?;
    let (prepared, preferences) = prepare(&super::db(&app)?, document, &categories)?;
    let summary = prepared.summary.clone();
    let path_references = prepared.path_references.clone();
    let missing_favorites = prepared.missing_favorites.clone();
    let token = state.issue(prepared)?;
    Ok(Some(Review {
        token,
        summary,
        path_references,
        missing_favorites,
        preferences,
    }))
}
#[tauri::command]
pub fn backup_apply_import(
    app: tauri::AppHandle,
    library: State<'_, Library>,
    state: State<'_, BackupState>,
    token: String,
) -> Result<Summary, String> {
    // Consume before all failure paths: retries must create and review a fresh snapshot.
    let prepared = state.take(&token)?;
    let _guard = library.lock.lock().map_err(|_| STALE)?;
    let summary = apply(&mut super::db(&app)?, prepared)?;
    drop(_guard);
    super::changed(&app);
    crate::snippet_expansion::refresh(&app);
    Ok(summary)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        super::super::schema(&db).unwrap();
        db
    }
    fn categories() -> Categories {
        Categories {
            snippets: true,
            quicklinks: true,
            path_links: false,
            favorites: true,
            preferences: false,
        }
    }
    fn document() -> Document {
        Document {
            format: "prism-backup".into(),
            version: 1,
            entries: vec![BackupEntry {
                id: "one".into(),
                kind: "snippet".into(),
                title: "Example".into(),
                value: "Hello".into(),
                keyword: None,
            }],
            favorites: vec![BackupFavorite {
                id: "library:one".into(),
                title: "Example".into(),
            }],
            preferences: None,
        }
    }
    #[test]
    fn path_references_are_opt_in_and_never_restore_roots() {
        let fixture = Fixture::new();
        let mut db = db();
        let mut doc = document();
        doc.entries.clear();
        doc.favorites.clear();
        for (id, path) in [
            ("existing", fixture.0.clone()),
            ("missing", fixture.0.join("absent")),
        ] {
            doc.entries.push(BackupEntry {
                id: id.into(),
                kind: "path".into(),
                title: id.into(),
                value: path.to_string_lossy().into(),
                keyword: None,
            });
        }
        let (prepared, _) = prepare(&db, doc.clone(), &categories()).unwrap();
        assert!(prepared.entries.is_empty());
        assert!(prepared.path_references.is_empty());
        let mut selected = categories();
        selected.path_links = true;
        let (prepared, _) = prepare(&db, doc, &selected).unwrap();
        assert_eq!(prepared.summary.path_links.added, 2);
        assert_eq!(prepared.path_references[0].status, "existing");
        assert_eq!(prepared.path_references[1].status, "missing");
        apply(&mut db, prepared).unwrap();
        let data = super::super::read(&db).unwrap();
        assert_eq!(data.entries.len(), 2);
        assert!(data.roots.is_empty());
    }
    #[test]
    fn keyword_round_trip_and_conflicts_are_reviewed_before_mutation() {
        let mut db = db();
        let mut doc = document();
        doc.version = 2;
        doc.entries[0].keyword = Some(";hello".into());
        let parsed = parse(&serde_json::to_vec(&doc).unwrap()).unwrap();
        let (prepared, _) = prepare(&db, parsed, &categories()).unwrap();
        apply(&mut db, prepared).unwrap();
        assert_eq!(
            super::super::read(&db).unwrap().entries[0]
                .keyword
                .as_deref(),
            Some(";hello")
        );
        let before = baseline(&db).unwrap();
        doc.entries[0].id = "another".into();
        assert_eq!(
            prepare(&db, doc.clone(), &categories()).err().unwrap(),
            "A snippet keyword conflicts with another snippet. Nothing was imported."
        );
        assert_eq!(baseline(&db).unwrap(), before);
        let empty = self::db();
        doc.entries.push(doc.entries[0].clone());
        doc.entries[1].id = "third".into();
        assert!(prepare(&empty, doc, &categories()).is_err());
        assert!(super::super::read(&empty).unwrap().entries.is_empty());
    }
    #[test]
    fn errors_distinguish_malformed_future_and_unsupported_data() {
        assert_eq!(parse(b"{").err().unwrap(), MALFORMED);
        assert_eq!(
            parse(br#"{"version":999,"futurePayload":true}"#)
                .err()
                .unwrap(),
            NEWER
        );
        let mut value = serde_json::to_value(document()).unwrap();
        value["permissionGrants"] = serde_json::json!(["/"]);
        assert_eq!(
            parse(&serde_json::to_vec(&value).unwrap()).err().unwrap(),
            UNSUPPORTED
        );
        value.as_object_mut().unwrap().remove("permissionGrants");
        value["entries"][0]["keyword"] = serde_json::json!("invalid keyword");
        assert_eq!(
            parse(&serde_json::to_vec(&value).unwrap()).err().unwrap(),
            INVALID
        );
    }
    #[test]
    fn conservative_conflicts_preserve_existing_values_and_order() {
        let mut db = db();
        let mut old = document().entries.remove(0).entry();
        old.value = "Keep me".into();
        super::super::save(&db, &old).unwrap();
        db.execute(
            "INSERT INTO favorites VALUES('app:existing','Existing',0)",
            [],
        )
        .unwrap();
        let (prepared, _) = prepare(&db, document(), &categories()).unwrap();
        assert_eq!(prepared.summary.snippets.conflicts, 1);
        assert_eq!(prepared.summary.favorites.added, 1);
        apply(&mut db, prepared).unwrap();
        let data = super::super::read(&db).unwrap();
        assert_eq!(data.entries[0].value, "Keep me");
        assert_eq!(data.favorites[0].id, "app:existing");
    }
    #[test]
    fn selection_skips_dangling_library_favorites() {
        let db = db();
        let mut selected = categories();
        selected.snippets = false;
        let (prepared, _) = prepare(&db, document(), &selected).unwrap();
        assert!(prepared.entries.is_empty());
        assert_eq!(prepared.summary.favorites.skipped, 1);
    }
    #[test]
    fn malformed_oversized_future_and_duplicate_documents_are_rejected() {
        assert!(parse(b"{").is_err());
        assert!(parse(&vec![b' '; MAX_BYTES + 1]).is_err());
        let mut doc = document();
        doc.version = 3;
        assert!(doc.validate().is_err());
        doc.version = 1;
        doc.entries.push(doc.entries[0].clone());
        assert!(doc.validate().is_err());
        let mut value = serde_json::to_value(document()).unwrap();
        value["permissionGrants"] = serde_json::json!(["/"]);
        assert!(parse(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    #[test]
    fn reject_unsafe_entries_even_in_unselected_categories() {
        let db = db();
        let mut doc = document();
        doc.entries[0].kind = "path".into();
        doc.entries[0].value = "relative/path".into();
        let selected = Categories {
            snippets: false,
            quicklinks: false,
            path_links: false,
            favorites: true,
            preferences: false,
        };
        assert!(prepare(&db, doc, &selected).is_err());
        let mut doc = document();
        doc.entries[0].kind = "link".into();
        doc.entries[0].value = "javascript:alert(1)".into();
        assert!(doc.validate().is_err());
    }
    #[test]
    fn failed_apply_rolls_back_all_writes_and_fresh_review_can_retry() {
        let mut db = db();
        let before = baseline(&db).unwrap();
        db.execute_batch("CREATE TRIGGER fail_import BEFORE INSERT ON favorites BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
        let (prepared, _) = prepare(&db, document(), &categories()).unwrap();
        assert!(apply(&mut db, prepared).is_err());
        assert_eq!(baseline(&db).unwrap(), before);
        db.execute_batch("DROP TRIGGER fail_import").unwrap();
        let (prepared, _) = prepare(&db, document(), &categories()).unwrap();
        apply(&mut db, prepared).unwrap();
        assert_eq!(super::super::read(&db).unwrap().entries.len(), 1);
    }
    #[test]
    fn concurrent_mutation_invalidates_review_without_applying() {
        let mut db = db();
        let (prepared, _) = prepare(&db, document(), &categories()).unwrap();
        db.execute("INSERT INTO roots VALUES('root','/fixture')", [])
            .unwrap();
        let before = baseline(&db).unwrap();
        assert!(apply(&mut db, prepared).is_err());
        assert_eq!(baseline(&db).unwrap(), before);
    }
    #[test]
    fn tokens_are_single_use_and_new_review_invalidates_previous() {
        let db = db();
        let state = BackupState::default();
        let (prepared, _) = prepare(&db, document(), &categories()).unwrap();
        let first = state.issue(prepared).unwrap();
        let (prepared, _) = prepare(&db, document(), &categories()).unwrap();
        let second = state.issue(prepared).unwrap();
        assert_ne!(first, second);
        assert!(state.take(&first).is_err());
        assert!(state.take(&second).is_ok());
        assert!(state.take(&second).is_err());
    }
    #[test]
    fn expired_review_preserves_data() {
        let mut db = db();
        let (mut prepared, _) = prepare(&db, document(), &categories()).unwrap();
        prepared.created = Instant::now() - REVIEW_TTL - Duration::from_secs(1);
        assert!(apply(&mut db, prepared).is_err());
        assert!(super::super::read(&db).unwrap().entries.is_empty());
    }
    #[test]
    fn capacity_is_checked_before_any_writes() {
        let db = db();
        for i in 0..50 {
            db.execute(
                "INSERT INTO favorites VALUES(?1,'Fixture',?2)",
                params![format!("app:{i}"), i],
            )
            .unwrap();
        }
        assert!(prepare(&db, document(), &categories()).is_err());
        assert!(super::super::read(&db).unwrap().entries.is_empty());
    }
    #[test]
    fn safe_preferences_reject_extra_authority_and_out_of_range_values() {
        let value = serde_json::json!({"language":"ko","theme":"dark","reduceMotion":true,"backgroundOpacity":97,"backgroundBlur":44,"showApplicationIcons":true,"commandAliases":{"prism:settings":"설정"}});
        let prefs: SafePreferences = serde_json::from_value(value.clone()).unwrap();
        prefs.validate().unwrap();
        let mut unsafe_value = value.clone();
        unsafe_value["scriptDirectories"] = serde_json::json!(["/tmp"]);
        assert!(serde_json::from_value::<SafePreferences>(unsafe_value).is_err());
        let mut prefs = prefs;
        prefs
            .command_aliases
            .insert("native:fixture".into(), "가".repeat(80));
        prefs.validate().unwrap();
        prefs
            .command_aliases
            .insert("native:fixture".into(), "가".repeat(81));
        assert!(prefs.validate().is_err());
        prefs.command_aliases.remove("native:fixture");
        for opacity in [10.0, 40.0, 64.0, 100.0] {
            prefs.background_opacity = opacity;
            prefs.validate().unwrap();
        }
        for opacity in [9.0, 101.0] {
            prefs.background_opacity = opacity;
            assert!(prefs.validate().is_err());
        }
        prefs.background_opacity = 0.0;
        assert!(prefs.validate().is_err());
        prefs.background_opacity = 97.0;
        for blur in [0.0, 60.0, 120.0, 180.0, 240.0] {
            prefs.background_blur = blur;
            prefs.validate().unwrap();
        }
        for blur in [-1.0, 241.0] {
            prefs.background_blur = blur;
            assert!(prefs.validate().is_err());
        }
        prefs.background_blur = 28.0;
        prefs
            .command_aliases
            .insert("__proto__".into(), "unsafe".into());
        assert!(prefs.validate().is_err());
    }
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "prism-backup-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn export_is_complete_and_failed_rename_preserves_destination() {
        let fixture = Fixture::new();
        let path = fixture.0.join("backup.json");
        std::fs::write(&path, "old").unwrap();
        assert!(write_file(&path, &vec![b'x'; MAX_BYTES + 1]).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "old");
        let bytes = serde_json::to_vec(&document()).unwrap();
        write_file(&path, &bytes).unwrap();
        assert_eq!(read_file(&path).unwrap(), bytes);
        let blocked = fixture.0.join("blocked");
        std::fs::create_dir(&blocked).unwrap();
        std::fs::write(blocked.join("keep"), "keep").unwrap();
        assert!(write_file(&blocked, b"new").is_err());
        assert_eq!(
            std::fs::read_to_string(blocked.join("keep")).unwrap(),
            "keep"
        );
        assert!(std::fs::read_dir(&fixture.0).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")));
    }
    #[cfg(unix)]
    #[test]
    fn chooser_reader_rejects_symlinks_special_files_and_oversize_files() {
        let fixture = Fixture::new();
        let path = fixture.0.join("large");
        let file = std::fs::File::create(&path).unwrap();
        file.set_len(MAX_BYTES as u64 + 1).unwrap();
        assert!(read_file(&path).is_err());
        let link = fixture.0.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read_file(&link).is_err());
        assert!(read_file(&fixture.0).is_err());
        use std::os::unix::ffi::OsStrExt;
        let fifo = fixture.0.join("pipe");
        let c_path = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);
        assert!(read_file(&fifo).is_err());
    }
}
