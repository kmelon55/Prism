//! Bounded, persisted filename catalog with event-driven directory reconciliation.
//! Search never walks the filesystem; cached paths remain hints, not capabilities.
use super::{matches_file_type, search_key, FileHit, Root, MAX_FILES};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{mpsc, Arc, Mutex},
    time::{Duration, Instant, SystemTime},
};

pub(super) struct IndexedFile {
    pub hit: FileHit,
    key: String,
}
struct Directory {
    modified: Option<SystemTime>,
    entries: Vec<Arc<IndexedFile>>,
}
pub(super) struct Snapshot {
    pub generation: u64,
    pub limited: bool,
    directories: HashMap<(String, PathBuf), Arc<Directory>>,
    files: Vec<Arc<IndexedFile>>,
}
#[derive(Default)]
pub(super) struct IndexState {
    pub snapshot: Option<Arc<Snapshot>>,
    pub refreshing: bool,
    pub error: Option<String>,
    pub attempted: Option<Instant>,
    pub watcher: Option<(u64, EventWatcher)>,
    pub pending: HashSet<PathBuf>,
    pub force_pending: bool,
    pub watcher_error: Option<String>,
}
impl IndexState {
    pub fn current(&self, generation: u64) -> Option<&Arc<Snapshot>> {
        self.snapshot
            .as_ref()
            .filter(|s| s.generation == generation)
    }
    pub fn publish(&mut self, snapshot: Snapshot, generation: u64) -> bool {
        self.refreshing = false;
        if snapshot.generation != generation {
            return false;
        }
        self.snapshot = Some(Arc::new(snapshot));
        self.error = None;
        true
    }
}
pub(super) fn excluded(name: &str) -> bool {
    name.starts_with('.')
        || [
            "node_modules",
            "target",
            "dist",
            "build",
            "Library",
            "vendor",
            "venv",
            "__pycache__",
            "Pods",
        ]
        .contains(&name)
}
impl Snapshot {
    pub fn page(
        &self,
        query: &str,
        filter: &str,
        offset: usize,
        limit: usize,
    ) -> (Vec<FileHit>, usize) {
        let matcher = FilenameQuery::new(query);
        let mut matched = 0;
        let mut page = Vec::with_capacity(limit.min(100));
        // Compute the expensive Unicode/token match once per file. One byte per
        // catalog row (at most 100 KiB) keeps rank buckets stable without sorting
        // or cloning the full result set on every keystroke.
        let ranks: Vec<u8> = self
            .files
            .iter()
            .map(|file| {
                if matches_file_type(&file.hit, filter) {
                    matcher.rank(&file.key).unwrap_or(u8::MAX)
                } else {
                    u8::MAX
                }
            })
            .collect();
        let total = ranks.iter().filter(|rank| **rank != u8::MAX).count();
        for rank in 0..5 {
            for (file, actual_rank) in self.files.iter().zip(&ranks) {
                if *actual_rank != rank {
                    continue;
                }
                if matched >= offset && page.len() < limit {
                    page.push(file.hit.clone());
                }
                matched += 1;
                if page.len() == limit {
                    return (page, total);
                }
            }
        }
        (page, total)
    }
}
pub(super) fn refresh(
    roots: &[Root],
    generation: u64,
    previous: Option<&Snapshot>,
    cancel: impl Fn() -> bool,
) -> Snapshot {
    refresh_bounded(
        roots,
        generation,
        previous,
        cancel,
        MAX_FILES,
        Duration::from_secs(5),
        None,
    )
}
fn refresh_bounded(
    roots: &[Root],
    generation: u64,
    previous: Option<&Snapshot>,
    cancel: impl Fn() -> bool,
    max_files: usize,
    budget: Duration,
    dirty: Option<&HashSet<PathBuf>>,
) -> Snapshot {
    let mut directories = HashMap::new();
    let mut files = Vec::new();
    let mut seen = HashSet::new();
    let mut queue = VecDeque::new();
    let mut limited = false;
    let mut visited = 0;
    let started = Instant::now();
    for root in roots {
        queue.push_back((root, PathBuf::from(&root.path), 0));
    }
    'walk: while let Some((root, path, depth)) = queue.pop_front() {
        if cancel() {
            break;
        }
        if started.elapsed() >= budget {
            limited = true;
            break;
        }
        let key = (root.id.clone(), path.clone());
        let old = previous.and_then(|s| s.directories.get(&key));
        // An event batch only touches changed directories and newly discovered
        // descendants. Unchanged listings are traversed in memory without stat.
        let unchanged = dirty.is_some_and(|paths| !paths.contains(&path)) && old.is_some();
        let modified = if unchanged {
            old.and_then(|d| d.modified)
        } else {
            if path.canonicalize().ok().as_ref() != Some(&path) {
                limited = true;
                continue;
            }
            let Ok(metadata) = std::fs::symlink_metadata(&path) else {
                limited = true;
                continue;
            };
            if !metadata.is_dir() || metadata.is_symlink() {
                limited = true;
                continue;
            }
            metadata.modified().ok()
        };
        let cached = old.filter(|d| {
            unchanged || (dirty.is_none() && modified.is_some() && d.modified == modified)
        });
        let mut exhausted = false;
        let directory = if let Some(cached) = cached {
            Arc::clone(cached)
        } else {
            let Ok(entries) = std::fs::read_dir(&path) else {
                limited = true;
                continue;
            };
            let mut rows = Vec::new();
            let mut unreadable = false;
            for entry in entries {
                visited += 1;
                if visited > max_files || cancel() || started.elapsed() >= budget {
                    limited = true;
                    exhausted = true;
                    break;
                }
                let Ok(entry) = entry else {
                    limited = true;
                    unreadable = true;
                    continue;
                };
                let name = entry.file_name().to_string_lossy().into_owned();
                if excluded(&name) {
                    continue;
                }
                let Ok(kind) = entry.file_type() else {
                    limited = true;
                    unreadable = true;
                    continue;
                };
                if kind.is_symlink() || (!kind.is_file() && !kind.is_dir()) {
                    continue;
                }
                let entry_path = entry.path();
                let Ok(relative) = entry_path.strip_prefix(&root.path) else {
                    continue;
                };
                rows.push(Arc::new(IndexedFile {
                    key: search_key(&name),
                    hit: FileHit {
                        id: format!("{}:{}", root.id, relative.to_string_lossy()),
                        name,
                        path: entry_path.to_string_lossy().into_owned(),
                        is_directory: kind.is_dir(),
                    },
                }));
            }
            Arc::new(Directory {
                // A partial listing must be retried, even when its mtime is stable.
                modified: if exhausted || unreadable {
                    None
                } else {
                    modified
                },
                entries: rows,
            })
        };
        for file in &directory.entries {
            if files.len() >= max_files {
                limited = true;
                break 'walk;
            }
            if seen.insert(file.hit.path.clone()) {
                files.push(Arc::clone(file));
            }
            if file.hit.is_directory && !file.hit.name.ends_with(".app") {
                if depth < 16 {
                    queue.push_back((root, PathBuf::from(&file.hit.path), depth + 1));
                } else {
                    limited = true;
                }
            }
        }
        directories.insert(key, directory);
        if exhausted {
            break;
        }
    }
    files.sort_unstable_by(|a, b| a.key.cmp(&b.key).then_with(|| a.hit.path.cmp(&b.hit.path)));
    Snapshot {
        generation,
        limited,
        directories,
        files,
    }
}

// Query work is capped independently of the catalog size. NFKC joins decomposed
// Hangul and folds compatibility forms; all tokens must match the filename.
pub(super) struct FilenameQuery {
    phrase: String,
    tokens: Vec<(String, Vec<char>)>,
    valid: bool,
}
impl FilenameQuery {
    pub fn new(query: &str) -> Self {
        let phrase = search_key(query.trim());
        let tokens: Vec<_> = phrase
            .split_whitespace()
            .take(9)
            .map(|token| (token.to_owned(), token.chars().collect::<Vec<_>>()))
            .collect();
        let valid = phrase.len() <= 512 && tokens.len() <= 8;
        Self {
            phrase,
            tokens,
            valid,
        }
    }
    pub fn rank(&self, key: &str) -> Option<u8> {
        if !self.valid {
            return None;
        }
        if key == self.phrase {
            return Some(0);
        }
        if key.starts_with(&self.phrase) {
            return Some(1);
        }
        if key.contains(&self.phrase) {
            return Some(2);
        }
        if self.tokens.iter().all(|(token, _)| key.contains(token)) {
            return Some(3);
        }
        if self.tokens.iter().all(|(token, chars)| {
            if key.contains(token) {
                return true;
            }
            // Avoid very short, noisy fuzzy matches and unbounded gaps.
            let count = chars.len();
            if !(3..=64).contains(&count) {
                return false;
            }
            let mut matched = 0;
            let mut span = 0;
            for c in key.chars().take(1024) {
                if matched > 0 {
                    span += 1;
                }
                if span > count * 3 {
                    return false;
                }
                if chars[matched] == c {
                    matched += 1;
                    if matched == count {
                        return true;
                    }
                }
            }
            false
        }) {
            Some(4)
        } else {
            None
        }
    }
}

pub(super) fn refresh_incremental(
    roots: &[Root],
    generation: u64,
    previous: &Snapshot,
    paths: &HashSet<PathBuf>,
    cancel: impl Fn() -> bool,
) -> Snapshot {
    let mut dirty = HashSet::new();
    for path in paths {
        dirty.insert(path.clone());
        if let Some(parent) = path.parent() {
            dirty.insert(parent.to_path_buf());
        }
    }
    // Directory create/remove/rename invalidates the changed subtree, including
    // same-name replacements whose children may have unrelated mtimes.
    let previous = Snapshot {
        generation: previous.generation,
        limited: previous.limited,
        directories: previous
            .directories
            .iter()
            .filter(|((_, directory), _)| !paths.iter().any(|path| directory.starts_with(path)))
            .map(|(key, value)| (key.clone(), Arc::clone(value)))
            .collect(),
        files: Vec::new(),
    };
    let mut next = refresh_bounded(
        roots,
        generation,
        Some(&previous),
        cancel,
        MAX_FILES,
        Duration::from_secs(5),
        Some(&dirty),
    );
    // Event updates cannot prove that a previous capped scan was complete.
    next.limited |= previous.limited;
    next
}

const CACHE_VERSION: u32 = 1;
const MAX_CACHE_BYTES: u64 = 32 * 1024 * 1024;
#[derive(Serialize, Deserialize, PartialEq, Eq)]
struct RootStamp {
    id: String,
    path: String,
    identity: String,
}
fn root_stamps(roots: &[Root]) -> Option<Vec<RootStamp>> {
    let mut result = Vec::new();
    for root in roots {
        let path = Path::new(&root.path);
        if path.canonicalize().ok()?.as_path() != path {
            return None;
        }
        let metadata = std::fs::symlink_metadata(path).ok()?;
        if !metadata.is_dir() || metadata.is_symlink() {
            return None;
        }
        #[cfg(unix)]
        let identity = {
            use std::os::unix::fs::MetadataExt;
            format!("{}:{}", metadata.dev(), metadata.ino())
        };
        #[cfg(not(unix))]
        let identity = format!("{:?}", metadata.created().ok()?);
        result.push(RootStamp {
            id: root.id.clone(),
            path: root.path.clone(),
            identity,
        });
    }
    result.sort_by(|a, b| a.id.cmp(&b.id).then(a.path.cmp(&b.path)));
    Some(result)
}
#[derive(Serialize, Deserialize)]
struct DiskDirectory {
    root_id: String,
    path: PathBuf,
    modified: Option<SystemTime>,
    entries: Vec<FileHit>,
}
#[derive(Serialize, Deserialize)]
struct DiskSnapshot {
    version: u32,
    roots: Vec<RootStamp>,
    limited: bool,
    directories: Vec<DiskDirectory>,
}
fn allowed_relative(path: &Path, root: &Path, allow_root: bool) -> bool {
    let Ok(relative) = path.strip_prefix(root) else {
        return false;
    };
    if relative.as_os_str().is_empty() {
        return allow_root;
    }
    let components: Vec<_> = relative.components().collect();
    components.len() <= 18
        && components.iter().enumerate().all(|(i, c)| {
            matches!(c, std::path::Component::Normal(_))
                && !excluded(&c.as_os_str().to_string_lossy())
                && (i + 1 == components.len() || !c.as_os_str().to_string_lossy().ends_with(".app"))
        })
}
pub(super) fn load_cache(path: &Path, roots: &[Root], generation: u64) -> Option<Snapshot> {
    let file = std::fs::File::open(path).ok()?;
    if file.metadata().ok()?.len() > MAX_CACHE_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_CACHE_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAX_CACHE_BYTES {
        return None;
    }
    let disk: DiskSnapshot = serde_json::from_slice(&bytes).ok()?;
    if disk.version != CACHE_VERSION
        || disk.roots != root_stamps(roots)?
        || disk.directories.len() > MAX_FILES
    {
        return None;
    }
    let mut directories = HashMap::new();
    let mut files = Vec::new();
    let mut seen = HashSet::new();
    let mut count = 0;
    for directory in disk.directories {
        let root = roots.iter().find(|root| root.id == directory.root_id)?;
        if !allowed_relative(&directory.path, Path::new(&root.path), true)
            || directory.path.to_string_lossy().len() > 4096
        {
            return None;
        }
        let mut entries = Vec::new();
        for hit in directory.entries {
            count += 1;
            let path = Path::new(&hit.path);
            if count > MAX_FILES
                || hit.path.len() > 4096
                || hit.name.len() > 1024
                || path.parent() != Some(directory.path.as_path())
                || path.file_name()?.to_string_lossy() != hit.name
                || !allowed_relative(path, Path::new(&root.path), false)
                || hit.id
                    != format!(
                        "{}:{}",
                        root.id,
                        path.strip_prefix(&root.path).ok()?.to_string_lossy()
                    )
            {
                return None;
            }
            let file = Arc::new(IndexedFile {
                key: search_key(&hit.name),
                hit,
            });
            if seen.insert(file.hit.path.clone()) {
                files.push(Arc::clone(&file));
            }
            entries.push(file);
        }
        if directories
            .insert(
                (directory.root_id, directory.path),
                Arc::new(Directory {
                    modified: directory.modified,
                    entries,
                }),
            )
            .is_some()
        {
            return None;
        }
    }
    files.sort_unstable_by(|a, b| a.key.cmp(&b.key).then(a.hit.path.cmp(&b.hit.path)));
    Some(Snapshot {
        generation,
        limited: disk.limited,
        directories,
        files,
    })
}
struct BoundedWriter<W> {
    inner: W,
    remaining: u64,
}
impl<W: Write> Write for BoundedWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if buf.len() as u64 > self.remaining {
            return Err(std::io::Error::other(
                "File index cache exceeds its byte limit",
            ));
        }
        let written = self.inner.write(buf)?;
        self.remaining -= written as u64;
        Ok(written)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
pub(super) fn save_cache(path: &Path, roots: &[Root], snapshot: &Snapshot) -> std::io::Result<()> {
    let roots = root_stamps(roots).ok_or_else(|| std::io::Error::other("Search roots changed"))?;
    let disk = DiskSnapshot {
        version: CACHE_VERSION,
        roots,
        limited: snapshot.limited,
        directories: snapshot
            .directories
            .iter()
            .map(|((root_id, path), directory)| DiskDirectory {
                root_id: root_id.clone(),
                path: path.clone(),
                modified: directory.modified,
                entries: directory
                    .entries
                    .iter()
                    .map(|file| file.hit.clone())
                    .collect(),
            })
            .collect(),
    };
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("Invalid cache path"))?;
    std::fs::create_dir_all(parent)?;
    let temporary = path.with_extension("tmp");
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        // A crashed write must not prevent future snapshots.
        let _ = std::fs::remove_file(&temporary);
        let file = options.open(&temporary)?;
        let mut writer = BoundedWriter {
            inner: std::io::BufWriter::new(file),
            remaining: MAX_CACHE_BYTES,
        };
        serde_json::to_writer(&mut writer, &disk).map_err(std::io::Error::other)?;
        writer.flush()?;
        writer.inner.get_ref().sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

const MAX_PENDING_PATHS: usize = 512;
const DEBOUNCE: Duration = Duration::from_millis(250);
const MAX_DEBOUNCE: Duration = Duration::from_secs(1);
#[derive(Default)]
struct PendingEvents {
    paths: HashSet<PathBuf>,
    overflow: bool,
}
impl PendingEvents {
    fn push(&mut self, roots: &[Root], event: Event) -> bool {
        if matches!(event.kind, EventKind::Access(_)) {
            return false;
        }
        let mut accepted = false;
        if event.need_rescan() {
            self.overflow = true;
            accepted = true;
        }
        for path in event.paths {
            // Exclude noisy/private trees BEFORE storing a path or waking a worker.
            if path.to_string_lossy().len() > 4096
                || !roots
                    .iter()
                    .any(|root| allowed_relative(&path, Path::new(&root.path), true))
            {
                continue;
            }
            accepted = true;
            if self.paths.contains(&path) {
                continue;
            }
            if self.paths.len() < MAX_PENDING_PATHS {
                self.paths.insert(path);
            } else {
                self.overflow = true;
            }
        }
        accepted
    }
    fn take(&mut self, roots: &[Root]) -> HashSet<PathBuf> {
        if self.overflow {
            self.overflow = false;
            self.paths.clear();
            roots.iter().map(|r| PathBuf::from(&r.path)).collect()
        } else {
            std::mem::take(&mut self.paths)
        }
    }
}
pub(super) struct EventWatcher {
    _watcher: RecommendedWatcher,
}
impl EventWatcher {
    pub fn start(
        roots: Vec<Root>,
        updated: impl Fn(HashSet<PathBuf>) + Send + 'static,
    ) -> Result<(Self, Option<String>), String> {
        let pending = Arc::new(Mutex::new(PendingEvents::default()));
        let (sender, receiver) = mpsc::sync_channel(1);
        let callback_pending = Arc::clone(&pending);
        let callback_roots = roots.clone();
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
            if let Ok(mut pending) = callback_pending.lock() {
                let accepted = match event {
                    Ok(event) => pending.push(&callback_roots, event),
                    Err(_) => {
                        pending.overflow = true;
                        true
                    }
                };
                if accepted {
                    let _ = sender.try_send(());
                }
            }
        })
        .map_err(|_| {
            "파일 변경 감시를 시작하지 못했습니다. 목록을 직접 새로고침하세요.".to_string()
        })?;
        let mut watched = HashSet::new();
        let mut failures = 0;
        let mut successes = 0;
        for root in &roots {
            if watched.insert(root.path.clone()) {
                if watcher
                    .watch(Path::new(&root.path), RecursiveMode::Recursive)
                    .is_ok()
                {
                    successes += 1;
                } else {
                    failures += 1;
                }
            }
        }
        let warning = (failures > 0).then(|| {
            "일부 폴더의 변경을 감시하지 못했습니다. 목록을 직접 새로고침하세요.".to_string()
        });
        if successes == 0 {
            return Err(warning.unwrap_or_else(|| "검색 폴더에 접근하지 못했습니다.".into()));
        }
        std::thread::Builder::new()
            .name("prism-file-events".into())
            .spawn(move || {
                while receiver.recv().is_ok() {
                    let started = Instant::now();
                    loop {
                        let remaining = MAX_DEBOUNCE.saturating_sub(started.elapsed());
                        if remaining.is_zero() {
                            break;
                        }
                        match receiver.recv_timeout(DEBOUNCE.min(remaining)) {
                            Ok(()) => (),
                            Err(mpsc::RecvTimeoutError::Timeout) => break,
                            Err(mpsc::RecvTimeoutError::Disconnected) => return,
                        }
                    }
                    let paths = pending
                        .lock()
                        .map(|mut p| p.take(&roots))
                        .unwrap_or_default();
                    if !paths.is_empty() {
                        updated(paths);
                    }
                }
            })
            .map_err(|_| "파일 변경 감시 작업을 시작하지 못했습니다.".to_string())?;
        Ok((Self { _watcher: watcher }, warning))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    static NEXT_FIXTURE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "prism-file-index-{}-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                NEXT_FIXTURE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path.canonicalize().unwrap())
        }
        fn roots(&self) -> Vec<Root> {
            vec![Root {
                id: "fixture".into(),
                path: self.0.to_string_lossy().into_owned(),
            }]
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    #[ignore = "Synthetic query timing only; run explicitly with --ignored --nocapture"]
    fn synthetic_100k_query_timing() {
        // No filesystem calls: this measures catalog query work, not startup,
        // native watcher latency, IPC, or packaged UI behavior.
        let mut files: Vec<_> = (0..MAX_FILES)
            .map(|i| {
                let name = format!("report-{i:06}-최종.txt");
                Arc::new(IndexedFile {
                    key: search_key(&name),
                    hit: FileHit {
                        id: format!("synthetic:{i}"),
                        name,
                        path: format!("/synthetic/{i:06}.txt"),
                        is_directory: false,
                    },
                })
            })
            .collect();
        files.sort_unstable_by(|a, b| a.key.cmp(&b.key).then(a.hit.path.cmp(&b.hit.path)));
        let snapshot = Snapshot {
            generation: 0,
            limited: false,
            directories: HashMap::new(),
            files,
        };
        for query in ["report", "최종 report", "rprt", "missing", "최종"] {
            let mut samples = Vec::new();
            for _ in 0..5 {
                let started = Instant::now();
                let (page, _) = snapshot.page(query, "text", 40, 40);
                assert!(page.len() <= 40);
                samples.push(started.elapsed());
            }
            samples.sort();
            eprintln!(
                "100k query {query:?}: median={:?}, max={:?}",
                samples[2], samples[4]
            );
        }
    }
    #[test]
    fn cache_round_trip_rejects_revoked_changed_and_replaced_roots() {
        let fixture = Fixture::new();
        let roots = fixture.roots();
        std::fs::write(fixture.0.join("report.txt"), "x").unwrap();
        let snapshot = refresh(&roots, 1, None, || false);
        let cache = fixture.0.join(".cache.json");
        save_cache(&cache, &roots, &snapshot).unwrap();
        let loaded = load_cache(&cache, &roots, 9).unwrap();
        assert_eq!(loaded.generation, 9);
        assert_eq!(loaded.page("report", "all", 0, 10).1, 1);
        assert!(load_cache(&cache, &[], 9).is_none());
        assert!(load_cache(
            &cache,
            &[Root {
                id: "changed".into(),
                path: roots[0].path.clone()
            }],
            9
        )
        .is_none());
        let other = Fixture::new();
        assert!(load_cache(&cache, &other.roots(), 9).is_none());
        // Cache contents remain portable across generations, never across identities.
        let bytes = std::fs::read(&cache).unwrap();
        let moved = fixture.0.with_extension("moved");
        std::fs::rename(&fixture.0, &moved).unwrap();
        std::fs::create_dir(&fixture.0).unwrap();
        std::fs::write(&cache, bytes).unwrap();
        assert!(load_cache(&cache, &roots, 9).is_none());
        std::fs::remove_dir_all(moved).unwrap();
    }
    #[test]
    fn cache_rejects_corruption_versions_oversize_and_forged_paths() {
        let fixture = Fixture::new();
        let roots = fixture.roots();
        std::fs::write(fixture.0.join("report.txt"), "x").unwrap();
        let snapshot = refresh(&roots, 1, None, || false);
        let cache = fixture.0.join(".cache.json");
        std::fs::write(&cache, b"{broken").unwrap();
        assert!(load_cache(&cache, &roots, 0).is_none());
        save_cache(&cache, &roots, &snapshot).unwrap();
        let valid = std::fs::read(&cache).unwrap();
        let mut disk: serde_json::Value = serde_json::from_slice(&valid).unwrap();
        disk["version"] = 999.into();
        std::fs::write(&cache, serde_json::to_vec(&disk).unwrap()).unwrap();
        assert!(load_cache(&cache, &roots, 0).is_none());
        disk = serde_json::from_slice(&valid).unwrap();
        disk["directories"][0]["entries"][0]["path"] = "/outside/secret".into();
        std::fs::write(&cache, serde_json::to_vec(&disk).unwrap()).unwrap();
        assert!(load_cache(&cache, &roots, 0).is_none());
        std::fs::File::create(&cache)
            .unwrap()
            .set_len(MAX_CACHE_BYTES + 1)
            .unwrap();
        assert!(load_cache(&cache, &roots, 0).is_none());
        let mut writer = BoundedWriter {
            inner: Vec::new(),
            remaining: 3,
        };
        assert!(writer.write_all(b"four").is_err());
        assert!(writer.inner.is_empty());
    }
    #[test]
    fn event_filter_excludes_before_queueing_and_bounds_overflow() {
        use notify::event::{AccessKind, CreateKind, ModifyKind};
        let fixture = Fixture::new();
        let roots = fixture.roots();
        let mut pending = PendingEvents::default();
        for relative in [
            "node_modules/a.js",
            ".git/index",
            "Library/cache",
            "A.app/Contents/file",
            "target/debug/a",
        ] {
            assert!(!pending.push(
                &roots,
                Event::new(EventKind::Create(CreateKind::File)).add_path(fixture.0.join(relative))
            ));
        }
        assert!(!pending.push(
            &roots,
            Event::new(EventKind::Access(AccessKind::Any)).add_path(fixture.0.join("report.txt"))
        ));
        assert!(pending.paths.is_empty());
        assert!(!pending.overflow);
        for i in 0..(MAX_PENDING_PATHS + 5) {
            assert!(pending.push(
                &roots,
                Event::new(EventKind::Modify(ModifyKind::Any))
                    .add_path(fixture.0.join(format!("{i}.txt")))
            ));
        }
        assert_eq!(pending.paths.len(), MAX_PENDING_PATHS);
        assert!(pending.overflow);
        assert_eq!(pending.take(&roots), HashSet::from([fixture.0.clone()]));
        assert!(pending.paths.is_empty());
        assert!(!pending.overflow);
    }
    #[test]
    fn events_reconcile_only_changed_listings_even_with_unchanged_mtimes() {
        let fixture = Fixture::new();
        std::fs::create_dir(fixture.0.join("stable")).unwrap();
        std::fs::create_dir(fixture.0.join("changed")).unwrap();
        std::fs::write(fixture.0.join("changed/old.txt"), "x").unwrap();
        let first = refresh(&fixture.roots(), 0, None, || false);
        let modified = std::fs::metadata(fixture.0.join("changed"))
            .unwrap()
            .modified()
            .unwrap();
        std::fs::remove_file(fixture.0.join("changed/old.txt")).unwrap();
        std::fs::write(fixture.0.join("changed/new.txt"), "x").unwrap();
        std::fs::File::open(fixture.0.join("changed"))
            .unwrap()
            .set_modified(modified)
            .unwrap();
        let next = refresh_incremental(
            &fixture.roots(),
            0,
            &first,
            &HashSet::from([
                fixture.0.join("changed/old.txt"),
                fixture.0.join("changed/new.txt"),
            ]),
            || false,
        );
        assert_eq!(next.page("old", "all", 0, 10).1, 0);
        assert_eq!(next.page("new", "all", 0, 10).1, 1);
        let key = ("fixture".into(), fixture.0.join("stable"));
        assert!(Arc::ptr_eq(
            &first.directories[&key],
            &next.directories[&key]
        ));
        let key = ("fixture".into(), fixture.0.clone());
        assert!(Arc::ptr_eq(
            &first.directories[&key],
            &next.directories[&key]
        ));
    }
    #[test]
    fn directory_rename_removes_descendants_and_discovers_new_subtree() {
        let fixture = Fixture::new();
        std::fs::create_dir_all(fixture.0.join("before/nested")).unwrap();
        std::fs::write(fixture.0.join("before/nested/report.txt"), "x").unwrap();
        let first = refresh(&fixture.roots(), 0, None, || false);
        std::fs::rename(fixture.0.join("before"), fixture.0.join("after")).unwrap();
        let next = refresh_incremental(
            &fixture.roots(),
            0,
            &first,
            &HashSet::from([fixture.0.join("before"), fixture.0.join("after")]),
            || false,
        );
        let (page, total) = next.page("report", "all", 0, 10);
        assert_eq!(total, 1);
        assert!(page[0].path.contains("/after/nested/"));
        assert!(next
            .directories
            .keys()
            .all(|(_, p)| !p.starts_with(fixture.0.join("before"))));
    }
    #[test]
    fn filename_tokens_subsequences_and_korean_have_stable_ranked_pages() {
        let fixture = Fixture::new();
        for name in [
            "report-final.txt",
            "final annual report.txt",
            "r-e-p-o-r-t.txt",
            "문서 최종.txt",
        ] {
            std::fs::write(fixture.0.join(name), "x").unwrap();
        }
        let snapshot = refresh(&fixture.roots(), 0, None, || false);
        assert_eq!(snapshot.page("final report", "all", 0, 10).1, 2);
        assert_eq!(snapshot.page("문서 최종", "all", 0, 10).1, 1);
        assert_eq!(snapshot.page("rpt", "all", 0, 10).1, 2);
        let all = snapshot.page("report", "all", 0, 10).0;
        let paged: Vec<_> = (0..all.len())
            .map(|offset| snapshot.page("report", "all", offset, 1).0.remove(0).path)
            .collect();
        assert_eq!(
            paged,
            all.into_iter().map(|file| file.path).collect::<Vec<_>>()
        );
        assert!(FilenameQuery::new("a b c d e f g h i")
            .rank("anything")
            .is_none());
        assert!(FilenameQuery::new("rp").rank("report").is_none());
    }
    #[test]
    fn stale_scan_cannot_publish_and_revoked_generation_is_invisible() {
        let fixture = Fixture::new();
        std::fs::write(fixture.0.join("secret.txt"), "x").unwrap();
        let mut state = IndexState::default();
        assert!(state.publish(refresh(&fixture.roots(), 1, None, || false), 1));
        assert!(state.current(2).is_none());
        assert!(!state.publish(refresh(&fixture.roots(), 1, None, || false), 2));
        assert!(state.publish(refresh(&[], 2, None, || false), 2));
        assert_eq!(state.current(2).unwrap().page("", "all", 0, 10).1, 0);
    }
    #[test]
    fn refresh_reuses_unchanged_directories_and_discovers_new_and_deleted_files() {
        let fixture = Fixture::new();
        std::fs::create_dir(fixture.0.join("stable")).unwrap();
        std::fs::write(fixture.0.join("old.txt"), "x").unwrap();
        let first = refresh(&fixture.roots(), 0, None, || false);
        std::fs::remove_file(fixture.0.join("old.txt")).unwrap();
        std::fs::write(fixture.0.join("new.txt"), "x").unwrap();
        // Force a distinct mtime without a timing-dependent sleep.
        std::fs::File::open(&fixture.0)
            .unwrap()
            .set_modified(SystemTime::now() + Duration::from_secs(1))
            .unwrap();
        let next = refresh(&fixture.roots(), 0, Some(&first), || false);
        assert_eq!(next.page("old", "all", 0, 10).1, 0);
        assert_eq!(next.page("new", "text", 0, 10).1, 1);
        let key = ("fixture".into(), fixture.0.join("stable"));
        assert!(Arc::ptr_eq(
            &first.directories[&key],
            &next.directories[&key]
        ));
    }
    #[test]
    fn query_order_is_stable_normalized_filtered_and_paginated() {
        let fixture = Fixture::new();
        for name in [
            "b-report.txt",
            "report-z.txt",
            "report-a.txt",
            "report.png",
            "문서.txt",
        ] {
            std::fs::write(fixture.0.join(name), "x").unwrap();
        }
        std::fs::create_dir(fixture.0.join("node_modules")).unwrap();
        std::fs::write(fixture.0.join("node_modules/hidden-report.txt"), "x").unwrap();
        let snapshot = refresh(&fixture.roots(), 0, None, || false);
        let (page, total) = snapshot.page("report", "text", 1, 2);
        assert_eq!(total, 3);
        assert_eq!(
            page.iter().map(|h| h.name.as_str()).collect::<Vec<_>>(),
            ["report-z.txt", "b-report.txt"]
        );
        assert_eq!(snapshot.page("문서", "text", 0, 1).1, 1);
        assert_eq!(snapshot.page("hidden", "all", 0, 1).1, 0);
    }
    #[test]
    fn flat_directory_limit_preserves_collected_rows_and_retries_partial_cache() {
        let fixture = Fixture::new();
        for name in ["one.txt", "two.txt", "three.txt", "four.txt"] {
            std::fs::write(fixture.0.join(name), "x").unwrap();
        }
        let partial = refresh_bounded(
            &fixture.roots(),
            0,
            None,
            || false,
            3,
            Duration::from_secs(5),
            None,
        );
        assert!(partial.limited);
        assert_eq!(partial.page("", "all", 0, 10).1, 3);
        let next = refresh(&fixture.roots(), 0, Some(&partial), || false);
        assert_eq!(next.page("", "all", 0, 10).1, 4);
        assert!(!next.limited);
    }
    #[test]
    fn expired_budget_does_not_read_directory_contents() {
        let fixture = Fixture::new();
        std::fs::write(fixture.0.join("one.txt"), "x").unwrap();
        let snapshot = refresh_bounded(
            &fixture.roots(),
            0,
            None,
            || false,
            100,
            Duration::ZERO,
            None,
        );
        assert!(snapshot.limited);
        assert_eq!(snapshot.page("", "all", 0, 10).1, 0);
    }
    #[cfg(unix)]
    #[test]
    fn replaced_root_and_cancelled_walk_do_not_return_cached_files() {
        let fixture = Fixture::new();
        let root_path = fixture.0.join("root");
        std::fs::create_dir(&root_path).unwrap();
        std::fs::write(root_path.join("secret.txt"), "x").unwrap();
        let roots = vec![Root {
            id: "root".into(),
            path: root_path.to_string_lossy().into_owned(),
        }];
        let first = refresh(&roots, 0, None, || false);
        assert_eq!(
            refresh(&roots, 0, Some(&first), || true)
                .page("", "all", 0, 10)
                .1,
            0
        );
        std::fs::rename(&root_path, fixture.0.join("moved")).unwrap();
        std::os::unix::fs::symlink(fixture.0.join("moved"), &root_path).unwrap();
        let next = refresh(&roots, 0, Some(&first), || false);
        assert!(next.limited);
        assert_eq!(next.page("", "all", 0, 10).1, 0);
    }
}
