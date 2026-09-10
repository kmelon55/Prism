use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::State;

const MAX_DIRECTORIES: usize = 32;
const MAX_ENTRIES: usize = 2_048;
const MAX_METADATA_BYTES: u64 = 8 * 1_024;
const MAX_CAPTURE_BYTES: usize = 64 * 1_024;
const DEFAULT_TIMEOUT_SECONDS: u64 = 10;
const MAX_TIMEOUT_SECONDS: u64 = 3_600;
#[cfg(test)]
const SCRIPT_TIMEOUT: Duration = Duration::from_secs(DEFAULT_TIMEOUT_SECONDS);
const MAX_RUNS: usize = 32;
const MAX_HISTORY_FILE_BYTES: u64 = 64 * 1_024 * 1_024;
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(1);
const OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(200);

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ScriptCommandSummary {
    id: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    keywords: Vec<String>,
    arguments: Vec<ScriptArgument>,
    argument_error: Option<String>,
    timeout_seconds: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefreshScriptCommandsResult {
    commands: Vec<ScriptCommandSummary>,
    scanned_directories: usize,
    skipped_entries: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptCommandRunResult {
    script_id: String,
    succeeded: bool,
    timed_out: bool,
    cancelled: bool,
    exit_code: Option<i32>,
    duration_ms: u64,
    stdout: String,
    stderr: String,
    stdout_truncated: bool,
    stderr_truncated: bool,
}

#[derive(Clone, Debug)]
struct RegisteredScript {
    summary: ScriptCommandSummary,
    path: PathBuf,
    root: PathBuf,
}

#[derive(Default)]
struct RegistryState {
    scripts: HashMap<String, RegisteredScript>,
    ordered: Vec<ScriptCommandSummary>,
}

#[derive(Default)]
pub struct ScriptCommandRegistry {
    state: RwLock<RegistryState>,
    next_id: AtomicU64,
    next_run_id: AtomicU64,
    runs: Mutex<HashMap<String, Arc<ScriptRun>>>,
    history: Arc<Mutex<RunHistory>>,
}

#[derive(Default)]
struct ScriptMetadata {
    timeout_seconds: Option<u64>,
    name: Option<String>,
    description: Option<String>,
    keywords: Vec<String>,
    arguments: Vec<ScriptArgument>,
    argument_error: Option<String>,
}

struct BoundedOutput {
    bytes: Mutex<Vec<u8>>,
    truncated: AtomicBool,
}

impl BoundedOutput {
    fn new() -> Self {
        Self {
            bytes: Mutex::new(Vec::with_capacity(MAX_CAPTURE_BYTES.min(8 * 1_024))),
            truncated: AtomicBool::new(false),
        }
    }

    fn append(&self, bytes: &[u8]) {
        let Ok(mut output) = self.bytes.lock() else {
            self.truncated.store(true, Ordering::Relaxed);
            return;
        };
        let remaining = MAX_CAPTURE_BYTES.saturating_sub(output.len());
        output.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
        if bytes.len() > remaining {
            self.truncated.store(true, Ordering::Relaxed);
        }
    }

    fn snapshot(&self) -> (String, bool) {
        let bytes = self
            .bytes
            .lock()
            .map(|bytes| bytes.clone())
            .unwrap_or_default();
        (
            String::from_utf8_lossy(&bytes).into_owned(),
            self.truncated.load(Ordering::Relaxed),
        )
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ScriptArgument {
    #[serde(rename = "type")]
    kind: String,
    placeholder: String,
    #[serde(default)]
    optional: bool,
    #[serde(default)]
    percent_encoded: bool,
    #[serde(default)]
    data: Vec<ScriptArgumentOption>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ScriptArgumentOption {
    title: String,
    value: String,
}

struct ScriptRun {
    script_id: String,
    run_id: String,
    started_at_ms: u64,
    timeout_seconds: u64,
    sensitive_output: bool,
    history: Option<Arc<Mutex<RunHistory>>>,
    persistence_error: Mutex<Option<String>>,
    publication: Mutex<()>,
    restored: Option<ScriptRunSnapshot>,
    cancel: AtomicBool,
    stdout: Arc<BoundedOutput>,
    stderr: Arc<BoundedOutput>,
    // None is running; completion is published only after process reaping and output drain.
    completion: Mutex<Option<Result<ScriptCommandRunResult, String>>>,
}

impl Default for ScriptRun {
    fn default() -> Self {
        Self {
            script_id: String::new(),
            run_id: String::new(),
            started_at_ms: 0,
            timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
            sensitive_output: false,
            history: None,
            persistence_error: Mutex::new(None),
            publication: Mutex::new(()),
            restored: None,
            cancel: AtomicBool::new(false),
            stdout: Arc::new(BoundedOutput::new()),
            stderr: Arc::new(BoundedOutput::new()),
            completion: Mutex::new(None),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptRunSnapshot {
    started_at_ms: u64,
    timeout_seconds: u64,
    output_withheld: bool,
    #[serde(default)]
    persistence_error: Option<String>,
    run_id: String,
    script_id: String,
    state: String,
    result: Option<ScriptCommandRunResult>,
    error: Option<String>,
    stdout: String,
    stderr: String,
    stdout_truncated: bool,
    stderr_truncated: bool,
}

fn run_snapshot(run_id: String, run: &ScriptRun) -> Result<ScriptRunSnapshot, String> {
    let _publication = run
        .publication
        .lock()
        .map_err(|_| "Script run is unavailable.")?;
    snapshot_unlocked(run_id, run)
}

fn snapshot_unlocked(run_id: String, run: &ScriptRun) -> Result<ScriptRunSnapshot, String> {
    if let Some(snapshot) = &run.restored {
        return Ok(snapshot.clone());
    }
    let completion = run
        .completion
        .lock()
        .map_err(|_| "Script run is unavailable.")?;
    let (state, result, error) = match completion.as_ref() {
        None => ("running", None, None),
        Some(Ok(result)) => (
            if result.cancelled {
                "cancelled"
            } else if result.timed_out {
                "timedOut"
            } else if result.succeeded {
                "success"
            } else {
                "failure"
            },
            Some(result.clone()),
            None,
        ),
        Some(Err(error)) => ("failure", None, Some(error.clone())),
    };
    let (stdout, stdout_truncated) = run.stdout.snapshot();
    let (stderr, stderr_truncated) = run.stderr.snapshot();
    Ok(ScriptRunSnapshot {
        started_at_ms: run.started_at_ms,
        timeout_seconds: run.timeout_seconds,
        output_withheld: false,
        persistence_error: run
            .persistence_error
            .lock()
            .ok()
            .and_then(|error| error.clone()),
        run_id,
        script_id: run.script_id.clone(),
        state: state.into(),
        result,
        error,
        stdout,
        stderr,
        stdout_truncated,
        stderr_truncated,
    })
}

#[derive(Clone, Default, Deserialize, Serialize)]
struct HistoryFile {
    version: u32,
    next_script_id: u64,
    next_run_id: u64,
    identities: Vec<ScriptIdentity>,
    runs: Vec<ScriptRunSnapshot>,
}

#[derive(Clone, Deserialize, Serialize)]
struct ScriptIdentity {
    path: PathBuf,
    root: PathBuf,
    id: String,
}

#[derive(Default)]
struct RunHistory {
    path: Option<PathBuf>,
    file: HistoryFile,
}

impl RunHistory {
    fn write(&self) -> Result<(), String> {
        let Some(path) = &self.path else {
            // Fixture registries intentionally have no access to the user's app data.
            #[cfg(test)]
            return Ok(());
            #[cfg(not(test))]
            return Err(
                "Script history is unavailable. Restart Prism to retry initialization.".into(),
            );
        };
        let mut file = self.file.clone();
        for snapshot in &mut file.runs {
            if let Some(result) = &mut snapshot.result {
                result.stdout.clear();
                result.stderr.clear();
            }
        }
        let bytes = serde_json::to_vec(&file)
            .map_err(|e| format!("Could not encode script history: {e}"))?;
        if bytes.len() as u64 > MAX_HISTORY_FILE_BYTES {
            return Err("Script history exceeded its storage limit.".into());
        }
        let temporary = path.with_extension("json.tmp");
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options
            .open(&temporary)
            .map_err(|e| format!("Could not save script history: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))
                .map_err(|e| e.to_string())?;
        }
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| format!("Could not save script history: {e}"))?;
        fs::rename(&temporary, path)
            .map_err(|e| format!("Could not replace script history: {e}"))?;
        // Flush the rename too, so an acknowledged initial checkpoint precedes execution.
        #[cfg(unix)]
        if let Some(parent) = path.parent() {
            fs::File::open(parent)
                .and_then(|directory| directory.sync_all())
                .map_err(|e| format!("Could not flush script history: {e}"))?;
        }
        Ok(())
    }
}

impl ScriptCommandRegistry {
    /// Call once during Tauri setup with an app-data path, before commands are served.
    pub fn initialize(&self, path: PathBuf) -> Result<(), String> {
        let mut history = self
            .history
            .lock()
            .map_err(|_| "Script history is unavailable.")?;
        if history.path.is_some() {
            return Err("Script history is already initialized.".into());
        }
        let parent = path.parent().ok_or("Script history path has no parent.")?;
        fs::create_dir_all(parent)
            .map_err(|e| format!("Could not create script history directory: {e}"))?;
        let mut saved = match fs::File::open(&path) {
            Ok(file) => {
                let mut bytes = Vec::new();
                file.take(MAX_HISTORY_FILE_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|e| e.to_string())?;
                if bytes.len() as u64 > MAX_HISTORY_FILE_BYTES {
                    return Err("Script history exceeded its storage limit.".into());
                }
                serde_json::from_slice::<HistoryFile>(&bytes)
                    .map_err(|e| format!("Could not read script history: {e}"))?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => HistoryFile {
                version: 1,
                ..HistoryFile::default()
            },
            Err(error) => return Err(format!("Could not read script history: {error}")),
        };
        if saved.version != 1 || saved.runs.len() > MAX_RUNS || saved.identities.len() > MAX_ENTRIES
        {
            return Err("Script history has an unsupported format or exceeds its limits.".into());
        }
        let mut ids = HashSet::new();
        for identity in &saved.identities {
            validate_script_id(&identity.id)?;
            if !ids.insert(identity.id.clone())
                || !identity.path.is_absolute()
                || !identity.root.is_absolute()
            {
                return Err("Script history contains invalid identities.".into());
            }
            saved.next_script_id = saved
                .next_script_id
                .max(u64::from_str_radix(&identity.id[3..], 16).map_err(|e| e.to_string())?);
        }
        let mut runs = HashMap::new();
        for snapshot in &mut saved.runs {
            let suffix = snapshot
                .run_id
                .strip_prefix("sr_")
                .ok_or("Invalid saved script run.")?;
            validate_script_id(&format!("sc_{suffix}"))?;
            validate_script_id(&snapshot.script_id)?;
            saved.next_run_id = saved
                .next_run_id
                .max(u64::from_str_radix(suffix, 16).map_err(|e| e.to_string())?);
            saved.next_script_id = saved
                .next_script_id
                .max(u64::from_str_radix(&snapshot.script_id[3..], 16).map_err(|e| e.to_string())?);
            if !(1..=MAX_TIMEOUT_SECONDS).contains(&snapshot.timeout_seconds)
                || snapshot.stdout.len() > MAX_CAPTURE_BYTES * 3
                || snapshot.stderr.len() > MAX_CAPTURE_BYTES * 3
                || !matches!(
                    snapshot.state.as_str(),
                    "running" | "success" | "failure" | "cancelled" | "timedOut" | "interrupted"
                )
            {
                return Err("Script history contains an invalid run.".into());
            }
            if snapshot.state == "running" {
                snapshot.state = "interrupted".into();
                snapshot.result = None;
                snapshot.error = Some("Prism restarted before this run finished. The process was not resumed. Review any side effects before running again.".into());
            }
            snapshot.persistence_error = None;
            if let Some(result) = &mut snapshot.result {
                result.stdout = snapshot.stdout.clone();
                result.stderr = snapshot.stderr.clone();
            }
            let run = ScriptRun {
                script_id: snapshot.script_id.clone(),
                restored: Some(snapshot.clone()),
                completion: Mutex::new(Some(Err("Recovered terminal run.".into()))),
                ..ScriptRun::default()
            };
            if runs
                .insert(snapshot.run_id.clone(), Arc::new(run))
                .is_some()
            {
                return Err("Script history contains duplicate runs.".into());
            }
        }
        let candidate = RunHistory {
            path: Some(path),
            file: saved,
        };
        candidate.write()?;
        self.next_id
            .store(candidate.file.next_script_id, Ordering::Relaxed);
        self.next_run_id
            .store(candidate.file.next_run_id, Ordering::Relaxed);
        *self
            .runs
            .lock()
            .map_err(|_| "Script runs are unavailable.")? = runs;
        *history = candidate;
        Ok(())
    }
}

fn checkpoint_run(run: &ScriptRun) -> Result<(), String> {
    let Some(history) = &run.history else {
        return Ok(());
    };
    let mut snapshot = snapshot_unlocked(run.run_id.clone(), run)?;
    snapshot.persistence_error = None;
    // Arguments are never serialized. Suppress both streams for password scripts,
    // including encoded/partial echoes that simple string redaction would miss.
    if run.sensitive_output {
        snapshot.stdout.clear();
        snapshot.stderr.clear();
        snapshot.output_withheld = true;
    }
    if let Some(result) = &mut snapshot.result {
        result.stdout.clear();
        result.stderr.clear();
    }
    let mut history = history
        .lock()
        .map_err(|_| "Script history is unavailable.")?;
    history
        .file
        .runs
        .retain(|saved| saved.run_id != snapshot.run_id);
    history.file.runs.push(snapshot);
    history.file.runs.sort_by(|a, b| a.run_id.cmp(&b.run_id));
    while history.file.runs.len() > MAX_RUNS {
        let index = history
            .file
            .runs
            .iter()
            .position(|run| run.state != "running")
            .ok_or("Too many active script runs.")?;
        history.file.runs.remove(index);
    }
    history.file.next_run_id = history
        .file
        .next_run_id
        .max(u64::from_str_radix(&run.run_id[3..], 16).map_err(|e| e.to_string())?);
    history.write()
}

fn save_run_progress(run: &ScriptRun) {
    let Ok(_publication) = run.publication.lock() else {
        return;
    };
    save_run_progress_unlocked(run);
}

fn complete_run(run: &ScriptRun, result: Result<ScriptCommandRunResult, String>) {
    let Ok(_publication) = run.publication.lock() else {
        return;
    };
    if let Ok(mut completion) = run.completion.lock() {
        *completion = Some(result);
    }
    // Publish terminal state together with its checkpoint outcome to observers.
    save_run_progress_unlocked(run);
}

fn save_run_progress_unlocked(run: &ScriptRun) {
    let error = checkpoint_run(run).err();
    if let Ok(mut current) = run.persistence_error.lock() {
        *current = error;
    }
}

fn resolve_run(registry: &ScriptCommandRegistry, run_id: &str) -> Result<Arc<ScriptRun>, String> {
    let suffix = run_id
        .strip_prefix("sr_")
        .ok_or("Invalid script run identifier.")?;
    validate_script_id(&format!("sc_{suffix}"))?;
    registry
        .runs
        .lock()
        .map_err(|_| "Script runs are unavailable.")?
        .get(run_id)
        .cloned()
        .ok_or_else(|| "Script run is no longer available.".into())
}

#[tauri::command]
pub fn start_script_command(
    script_id: String,
    args: Vec<String>,
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<ScriptRunSnapshot, String> {
    start_registered_run(registry.inner(), &script_id, args)
}

fn start_registered_run(
    registry: &ScriptCommandRegistry,
    script_id: &str,
    args: Vec<String>,
) -> Result<ScriptRunSnapshot, String> {
    let script = resolve_registered_script(registry, script_id)?;
    let args = validate_arguments(&script.summary, args)?;
    validate_registered_path(&script)?;
    let mut runs = registry
        .runs
        .lock()
        .map_err(|_| "Script runs are unavailable.")?;
    if runs.values().any(|run| {
        run.script_id == script_id && run.completion.lock().map(|r| r.is_none()).unwrap_or(true)
    }) {
        return Err(
            "This script is already running. Restore its status before starting again.".into(),
        );
    }
    let active = runs
        .values()
        .filter(|run| run.completion.lock().map(|r| r.is_none()).unwrap_or(true))
        .count();
    if active >= 4 {
        return Err("At most four script commands can run at once.".into());
    }
    if runs.len() >= MAX_RUNS {
        let oldest = runs
            .iter()
            .filter(|(_, run)| run.completion.lock().map(|r| r.is_some()).unwrap_or(false))
            .map(|(id, _)| id.clone())
            .min();
        if let Some(oldest) = oldest {
            runs.remove(&oldest);
        }
    }
    let sequence = registry
        .next_run_id
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
        .map_err(|_| "Script run identifiers exhausted.")?
        + 1;
    let id = format!("sr_{sequence:016x}");
    let timeout_seconds = script
        .summary
        .timeout_seconds
        .unwrap_or(DEFAULT_TIMEOUT_SECONDS);
    let run = Arc::new(ScriptRun {
        script_id: script_id.to_owned(),
        run_id: id.clone(),
        started_at_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64,
        timeout_seconds,
        sensitive_output: script
            .summary
            .arguments
            .iter()
            .any(|argument| argument.kind == "password"),
        history: Some(Arc::clone(&registry.history)),
        ..ScriptRun::default()
    });
    // Never launch if the initial durable record cannot be acknowledged.
    if let Err(error) = checkpoint_run(&run) {
        if let Ok(mut history) = registry.history.lock() {
            history.file.runs.retain(|saved| saved.run_id != id);
        }
        return Err(error);
    }
    runs.insert(id.clone(), Arc::clone(&run));
    drop(runs);
    let worker = Arc::clone(&run);
    if let Err(error) = thread::Builder::new()
        .name("prism-script".into())
        .spawn(move || {
            let result =
                execute_script(script, args, &worker, Duration::from_secs(timeout_seconds));
            complete_run(&worker, result);
        })
    {
        complete_run(&run, Err(format!("Could not start script worker: {error}")));
    }
    run_snapshot(id, &run)
}

/// Durable recovery and live observation; listing never executes a script or exposes arguments.
fn list_registered_runs(
    registry: &ScriptCommandRegistry,
) -> Result<Vec<ScriptRunSnapshot>, String> {
    #[cfg(not(test))]
    if registry
        .history
        .lock()
        .map_err(|_| "Script history is unavailable.")?
        .path
        .is_none()
    {
        return Err("Script history is unavailable. Restart Prism to retry initialization.".into());
    }
    let runs = registry
        .runs
        .lock()
        .map_err(|_| "Script runs are unavailable.")?;
    let mut snapshots = runs
        .iter()
        .map(|(id, run)| run_snapshot(id.clone(), run))
        .collect::<Result<Vec<_>, _>>()?;
    snapshots.sort_by(|left, right| left.run_id.cmp(&right.run_id));
    Ok(snapshots)
}

#[tauri::command]
pub fn list_script_command_runs(
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<Vec<ScriptRunSnapshot>, String> {
    list_registered_runs(registry.inner())
}

#[tauri::command]
pub fn get_script_command_run(
    run_id: String,
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<ScriptRunSnapshot, String> {
    let run = resolve_run(registry.inner(), &run_id)?;
    if run
        .persistence_error
        .lock()
        .map(|error| error.is_some())
        .unwrap_or(false)
    {
        save_run_progress(&run);
    }
    run_snapshot(run_id, &run)
}

#[tauri::command]
pub fn cancel_script_command(
    run_id: String,
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<ScriptRunSnapshot, String> {
    let run = resolve_run(registry.inner(), &run_id)?;
    run.cancel.store(true, Ordering::Release);
    run_snapshot(run_id, &run)
}

fn validate_arguments(
    summary: &ScriptCommandSummary,
    args: Vec<String>,
) -> Result<Vec<String>, String> {
    if let Some(error) = &summary.argument_error {
        return Err(error.clone());
    }
    if args.len() > summary.arguments.len() {
        return Err("Too many script arguments.".into());
    }
    summary
        .arguments
        .iter()
        .enumerate()
        .map(|(index, argument)| {
            let value = args.get(index).cloned().unwrap_or_default();
            if value.len() > 8192 || value.contains('\0') {
                return Err(format!("Argument {} is invalid or too long.", index + 1));
            }
            if !argument.optional && value.is_empty() {
                return Err(format!("Argument {} is required.", index + 1));
            }
            if argument.kind == "dropdown"
                && !(argument.optional && value.is_empty())
                && !argument.data.iter().any(|option| option.value == value)
            {
                return Err(format!(
                    "Argument {} must be one of the listed choices.",
                    index + 1
                ));
            }
            Ok(if argument.percent_encoded {
                percent_encode(&value)
            } else {
                value
            })
        })
        .collect()
}

fn percent_encode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

#[tauri::command]
pub fn refresh_script_commands(
    directories: Vec<String>,
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<RefreshScriptCommandsResult, String> {
    refresh_registry(registry.inner(), directories)
}

#[tauri::command]
pub fn list_script_commands(
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<Vec<ScriptCommandSummary>, String> {
    registry
        .state
        .read()
        .map(|state| state.ordered.clone())
        .map_err(|_| "The script command registry is temporarily unavailable.".to_string())
}

#[tauri::command]
pub async fn run_script_command(
    script_id: String,
    registry: State<'_, ScriptCommandRegistry>,
) -> Result<ScriptCommandRunResult, String> {
    let snapshot = start_registered_run(registry.inner(), &script_id, vec![])?;
    let run = resolve_run(registry.inner(), &snapshot.run_id)?;
    tauri::async_runtime::spawn_blocking(move || loop {
        if let Some(result) = run
            .completion
            .lock()
            .map_err(|_| "Script run is unavailable.")?
            .clone()
        {
            return result;
        }
        thread::sleep(Duration::from_millis(20));
    })
    .await
    .map_err(|error| format!("The script command did not finish: {error}"))?
}

fn refresh_registry(
    registry: &ScriptCommandRegistry,
    directories: Vec<String>,
) -> Result<RefreshScriptCommandsResult, String> {
    if directories.len() > MAX_DIRECTORIES {
        return Err(format!(
            "Prism accepts at most {MAX_DIRECTORIES} script directories."
        ));
    }

    let roots = canonicalize_directories(directories)?;
    let scanned_directories = roots.len();
    let mut discovered = Vec::new();
    let mut skipped_entries = 0usize;
    let mut inspected_entries = 0usize;

    for root in &roots {
        let entries = fs::read_dir(root).map_err(|error| {
            format!("Prism could not read a configured script directory: {error}")
        })?;

        for entry in entries {
            inspected_entries = inspected_entries.saturating_add(1);
            if inspected_entries > MAX_ENTRIES {
                return Err(format!(
                    "Prism stopped after inspecting {MAX_ENTRIES} script directory entries."
                ));
            }

            let Ok(entry) = entry else {
                skipped_entries = skipped_entries.saturating_add(1);
                continue;
            };
            let path = entry.path();
            let accepted = entry
                .file_type()
                .ok()
                .filter(|file_type| file_type.is_file())
                .and_then(|_| canonical_script_path(root, &path).ok())
                .filter(|path| is_supported_executable(path));
            let Some(path) = accepted else {
                skipped_entries = skipped_entries.saturating_add(1);
                continue;
            };

            let metadata = read_script_metadata(&path);
            let fallback_title = path
                .file_stem()
                .or_else(|| path.file_name())
                .map(|name| clean_fallback_title(&name.to_string_lossy()))
                .filter(|name| !name.is_empty())
                .unwrap_or_else(|| "Untitled script".to_string());
            discovered.push((
                path,
                root.clone(),
                metadata.name.unwrap_or(fallback_title),
                metadata.description,
                metadata.keywords,
                metadata.arguments,
                metadata.argument_error,
                metadata.timeout_seconds,
            ));
        }
    }

    discovered.sort_by(|left, right| {
        left.2
            .to_lowercase()
            .cmp(&right.2.to_lowercase())
            .then_with(|| left.0.cmp(&right.0))
    });

    // Hold the write lock through ID reuse and publication so concurrent refreshes cannot
    // publish different identities for the same canonical registered path.
    let mut state = registry
        .state
        .write()
        .map_err(|_| "The script command registry is temporarily unavailable.".to_string())?;
    let mut history = registry
        .history
        .lock()
        .map_err(|_| "Script history is unavailable.")?;
    let previous_ids: HashMap<_, _> = history
        .file
        .identities
        .iter()
        .map(|identity| {
            (
                (identity.path.clone(), identity.root.clone()),
                identity.id.clone(),
            )
        })
        .chain(state.scripts.values().map(|script| {
            (
                (script.path.clone(), script.root.clone()),
                script.summary.id.clone(),
            )
        }))
        .collect();
    let mut scripts = HashMap::with_capacity(discovered.len());
    let mut ordered = Vec::with_capacity(discovered.len());
    for (path, root, title, description, keywords, arguments, argument_error, timeout_seconds) in
        discovered
    {
        let id = match previous_ids.get(&(path.clone(), root.clone())) {
            Some(id) => id.clone(),
            None => allocate_script_id(registry)?,
        };
        let summary = ScriptCommandSummary {
            id: id.clone(),
            title,
            description,
            keywords,
            arguments,
            argument_error,
            timeout_seconds: Some(timeout_seconds.unwrap_or(DEFAULT_TIMEOUT_SECONDS)),
        };
        scripts.insert(
            id,
            RegisteredScript {
                summary: summary.clone(),
                path,
                root,
            },
        );
        ordered.push(summary);
    }

    history.file.identities = scripts
        .values()
        .map(|script| ScriptIdentity {
            path: script.path.clone(),
            root: script.root.clone(),
            id: script.summary.id.clone(),
        })
        .collect();
    history.file.next_script_id = registry.next_id.load(Ordering::Relaxed);
    history.file.version = 1;
    history.write()?;
    let commands = ordered.clone();
    *state = RegistryState { scripts, ordered };
    Ok(RefreshScriptCommandsResult {
        commands,
        scanned_directories,
        skipped_entries,
    })
}

fn canonicalize_directories(directories: Vec<String>) -> Result<Vec<PathBuf>, String> {
    let mut roots = Vec::with_capacity(directories.len());
    let mut seen = HashSet::with_capacity(directories.len());
    for directory in directories {
        if directory.is_empty()
            || directory.len() > 4_096
            || directory.chars().any(char::is_control)
        {
            return Err("A configured script directory path is invalid.".to_string());
        }
        let requested = PathBuf::from(directory);
        if !requested.is_absolute() {
            return Err("Configured script directories must be absolute paths.".to_string());
        }
        let root = fs::canonicalize(&requested).map_err(|error| {
            format!("Prism could not resolve a configured script directory: {error}")
        })?;
        if !root.is_dir() {
            return Err("A configured script directory is not a directory.".to_string());
        }
        if seen.insert(root.clone()) {
            roots.push(root);
        }
    }
    Ok(roots)
}

fn canonical_script_path(root: &Path, candidate: &Path) -> Result<PathBuf, String> {
    let canonical = fs::canonicalize(candidate)
        .map_err(|error| format!("Prism could not resolve a script command: {error}"))?;
    if canonical.parent() != Some(root) {
        return Err(
            "Prism rejected a script command outside its configured directory.".to_string(),
        );
    }
    Ok(canonical)
}

fn allocate_script_id(registry: &ScriptCommandRegistry) -> Result<String, String> {
    let sequence = registry
        .next_id
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            current.checked_add(1)
        })
        .map_err(|_| "The script command identifier space is exhausted.".to_string())?
        + 1;
    Ok(format!("sc_{sequence:016x}"))
}

fn validate_script_id(script_id: &str) -> Result<(), String> {
    let suffix = script_id
        .strip_prefix("sc_")
        .filter(|suffix| suffix.len() == 16)
        .ok_or_else(|| "The script command identifier is invalid.".to_string())?;
    if suffix == "0000000000000000"
        || !suffix
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("The script command identifier is invalid.".to_string());
    }
    Ok(())
}

fn resolve_registered_script(
    registry: &ScriptCommandRegistry,
    script_id: &str,
) -> Result<RegisteredScript, String> {
    validate_script_id(script_id)?;
    registry
        .state
        .read()
        .map_err(|_| "The script command registry is temporarily unavailable.".to_string())?
        .scripts
        .get(script_id)
        .cloned()
        .ok_or_else(|| "The script command is not present in the current registry.".to_string())
}

fn validate_registered_path(script: &RegisteredScript) -> Result<(), String> {
    let metadata = fs::symlink_metadata(&script.path)
        .map_err(|error| format!("Prism could not inspect the script command: {error}"))?;
    if !metadata.file_type().is_file() {
        return Err("The registered script command is no longer a regular file.".to_string());
    }
    let canonical = canonical_script_path(&script.root, &script.path)?;
    if canonical != script.path || !is_supported_executable(&canonical) {
        return Err("The registered script command is no longer executable.".to_string());
    }
    Ok(())
}

#[cfg(test)]
fn execute_registered_script(script: RegisteredScript) -> Result<ScriptCommandRunResult, String> {
    let args = validate_arguments(&script.summary, vec![])?;
    let timeout = Duration::from_secs(
        script
            .summary
            .timeout_seconds
            .unwrap_or(DEFAULT_TIMEOUT_SECONDS),
    );
    execute_script(script, args, &ScriptRun::default(), timeout)
}

fn execute_script(
    script: RegisteredScript,
    args: Vec<String>,
    run: &ScriptRun,
    timeout: Duration,
) -> Result<ScriptCommandRunResult, String> {
    validate_registered_path(&script)?;
    let started = Instant::now();
    let mut command = Command::new(&script.path);
    command
        .args(args)
        .current_dir(&script.root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("Prism could not start the script command: {error}"))?;

    let stdout = Arc::clone(&run.stdout);
    let stderr = Arc::clone(&run.stderr);
    let stdout_reader = child
        .stdout
        .take()
        .map(|reader| spawn_output_reader(reader, Arc::clone(&stdout)));
    let stderr_reader = child
        .stderr
        .take()
        .map(|reader| spawn_output_reader(reader, Arc::clone(&stderr)));

    let deadline = started + timeout;
    let mut checkpoint_at = Instant::now() + CHECKPOINT_INTERVAL;
    let (status, timed_out, cancelled) = loop {
        if Instant::now() >= checkpoint_at {
            save_run_progress(run);
            checkpoint_at = Instant::now() + CHECKPOINT_INTERVAL;
        }
        match child.try_wait() {
            Ok(Some(status)) => break (status, false, false),
            Ok(None) if run.cancel.load(Ordering::Acquire) => {
                break (terminate_script_process(&mut child)?, false, true);
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                let status = terminate_script_process(&mut child)?;
                break (status, true, false);
            }
            Err(error) => {
                terminate_script_process(&mut child).map_err(|termination_error| {
                    format!(
                        "Prism could not observe the script command ({error}); {termination_error}"
                    )
                })?;
                return Err(format!(
                    "Prism could not observe the script command: {error}"
                ));
            }
        }
    };

    // A foreground script must not leave background descendants holding its pipes open.
    #[cfg(unix)]
    if let Ok(group) = i32::try_from(child.id()) {
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
    }
    let [stdout_incomplete, stderr_incomplete] =
        finish_output_readers([stdout_reader, stderr_reader]);
    if stdout_incomplete {
        stdout.truncated.store(true, Ordering::Relaxed);
    }
    if stderr_incomplete {
        stderr.truncated.store(true, Ordering::Relaxed);
    }
    let (stdout, stdout_truncated) = stdout.snapshot();
    let (stderr, stderr_truncated) = stderr.snapshot();
    Ok(ScriptCommandRunResult {
        script_id: script.summary.id,
        succeeded: !timed_out && !cancelled && status.success(),
        timed_out,
        cancelled,
        exit_code: status.code(),
        duration_ms: started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
        stdout,
        stderr,
        stdout_truncated,
        stderr_truncated,
    })
}

fn terminate_script_process(child: &mut Child) -> Result<ExitStatus, String> {
    #[cfg(unix)]
    {
        let process_group = i32::try_from(child.id())
            .map_err(|_| "The script command process identifier is invalid.".to_string())?;
        let killed_group = unsafe { libc::kill(-process_group, libc::SIGKILL) } == 0;
        if !killed_group {
            child.kill().map_err(|error| {
                format!("Prism could not terminate the timed-out script command: {error}")
            })?;
        }
    }
    #[cfg(not(unix))]
    child.kill().map_err(|error| {
        format!("Prism could not terminate the timed-out script command: {error}")
    })?;

    child.wait().map_err(|error| {
        format!("Prism terminated the script command but could not reap it: {error}")
    })
}

fn spawn_output_reader<R>(mut reader: R, output: Arc<BoundedOutput>) -> thread::JoinHandle<()>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut chunk = [0u8; 8 * 1_024];
        loop {
            match reader.read(&mut chunk) {
                Ok(0) | Err(_) => return,
                Ok(count) => output.append(&chunk[..count]),
            }
        }
    })
}

fn finish_output_readers<const N: usize>(
    readers: [Option<thread::JoinHandle<()>>; N],
) -> [bool; N] {
    let deadline = Instant::now() + OUTPUT_DRAIN_GRACE;
    while Instant::now() < deadline && readers.iter().flatten().any(|reader| !reader.is_finished())
    {
        thread::sleep(Duration::from_millis(5));
    }
    let mut incomplete = [false; N];
    for (index, reader) in readers.into_iter().enumerate() {
        if let Some(reader) = reader {
            if reader.is_finished() {
                let _ = reader.join();
            } else {
                incomplete[index] = true;
            }
        }
    }
    incomplete
}

fn read_script_metadata(path: &Path) -> ScriptMetadata {
    let Ok(file) = fs::File::open(path) else {
        return ScriptMetadata::default();
    };
    let mut bytes = Vec::new();
    if file
        .take(MAX_METADATA_BYTES)
        .read_to_end(&mut bytes)
        .is_err()
    {
        return ScriptMetadata::default();
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut metadata = ScriptMetadata::default();
    let mut arguments = std::collections::BTreeMap::new();
    for line in text.lines().take(64) {
        let line = line.trim();
        let pair = line
            .strip_prefix("# prism:")
            .and_then(|v| v.split_once('='))
            .or_else(|| {
                line.strip_prefix("# @raycast.")
                    .and_then(|v| v.split_once(' '))
            });
        let Some((key, value)) = pair else {
            continue;
        };
        if let Some(index) = key.trim().strip_prefix("argument") {
            let parsed = index
                .parse::<usize>()
                .ok()
                .filter(|i| (1..=3).contains(i))
                .zip(serde_json::from_str::<ScriptArgument>(value.trim()).ok());
            if let Some((index, argument)) = parsed.filter(|(_, a)| valid_argument_metadata(a)) {
                if arguments.insert(index, argument).is_some() {
                    metadata.argument_error = Some("Duplicate script argument metadata.".into());
                }
            } else {
                metadata.argument_error = Some("Invalid script argument metadata.".into());
            }
            continue;
        }
        let value = value.trim();
        match key.trim() {
            "name" | "title" => metadata.name = validated_metadata_value(value, 120),
            "description" => metadata.description = validated_metadata_value(value, 240),
            "timeout" => {
                if let Some(seconds) = value
                    .parse::<u64>()
                    .ok()
                    .filter(|seconds| (1..=MAX_TIMEOUT_SECONDS).contains(seconds))
                {
                    metadata.timeout_seconds = Some(seconds);
                } else {
                    metadata.argument_error = Some(format!("Script timeout must be an integer between 1 and {MAX_TIMEOUT_SECONDS} seconds."));
                }
            }
            "keywords" => {
                metadata.keywords = value
                    .split(',')
                    .filter_map(|keyword| validated_metadata_value(keyword.trim(), 40))
                    .take(12)
                    .collect();
            }
            _ => {}
        }
    }
    for (expected, (index, argument)) in (1..).zip(arguments) {
        if index != expected {
            metadata.argument_error =
                Some("Script arguments must be numbered consecutively from 1.".into());
        }
        metadata.arguments.push(argument);
    }
    metadata
}

fn valid_argument_metadata(argument: &ScriptArgument) -> bool {
    matches!(argument.kind.as_str(), "text" | "password" | "dropdown")
        && validated_metadata_value(&argument.placeholder, 120).is_some()
        && argument.data.len() <= 100
        && (argument.kind != "dropdown" || !argument.data.is_empty())
        && argument.data.iter().all(|option| {
            validated_metadata_value(&option.title, 120).is_some()
                && !option.value.is_empty()
                && option.value.len() <= 8192
                && !option.value.contains('\0')
        })
}

fn validated_metadata_value(value: &str, maximum_characters: usize) -> Option<String> {
    let value = value.trim();
    if value.is_empty()
        || value.chars().count() > maximum_characters
        || value.chars().any(char::is_control)
    {
        return None;
    }
    Some(value.to_string())
}

fn clean_fallback_title(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .trim()
        .chars()
        .take(120)
        .collect()
}

#[cfg(unix)]
fn is_supported_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    const ALLOWED_EXTENSIONS: &[&str] = &["bash", "command", "fish", "pl", "py", "rb", "sh", "zsh"];
    let extension_is_supported = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            ALLOWED_EXTENSIONS
                .iter()
                .any(|allowed| extension.eq_ignore_ascii_case(allowed))
        })
        .unwrap_or(true);
    extension_is_supported
        && fs::metadata(path)
            .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

#[cfg(windows)]
fn is_supported_executable(path: &Path) -> bool {
    path.is_file()
        && path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| {
                extension.eq_ignore_ascii_case("exe") || extension.eq_ignore_ascii_case("com")
            })
            .unwrap_or(false)
}

#[cfg(not(any(unix, windows)))]
fn is_supported_executable(path: &Path) -> bool {
    path.is_file() && path.extension().is_none()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(1);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "prism-script-command-test-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        #[cfg(unix)]
        fn executable(&self, relative: &str, contents: &str) -> PathBuf {
            use std::os::unix::fs::PermissionsExt;

            let path = self.0.join(relative);
            fs::write(&path, contents).expect("write test script");
            let mut permissions = fs::metadata(&path).expect("script metadata").permissions();
            permissions.set_mode(0o700);
            fs::set_permissions(&path, permissions).expect("make test script executable");
            path
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn accepts_only_generated_identifier_shape() {
        assert!(validate_script_id("sc_0000000000000001").is_ok());
        for value in [
            "",
            "sc_0000000000000000",
            "sc_1",
            "sc_000000000000000A",
            "../sc_0000000000000001",
            "script_0000000000000001",
        ] {
            assert!(validate_script_id(value).is_err(), "accepted {value}");
        }
    }

    #[test]
    fn rejects_relative_and_non_directory_roots() {
        assert!(canonicalize_directories(vec!["relative/scripts".to_string()]).is_err());
        let directory = TestDirectory::new();
        let file = directory.0.join("file");
        fs::write(&file, "not a directory").expect("write test file");
        assert!(canonicalize_directories(vec![file.to_string_lossy().into_owned()]).is_err());
    }

    #[test]
    fn canonical_script_paths_cannot_escape_the_selected_root() {
        let directory = TestDirectory::new();
        let outside = TestDirectory::new();
        let outside_file = outside.0.join("outside.sh");
        fs::write(&outside_file, "outside").expect("write outside file");
        assert!(canonical_script_path(&directory.0, &outside_file).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn refresh_is_non_recursive_and_returns_only_opaque_ids() {
        let directory = TestDirectory::new();
        directory.executable(
            "hello.sh",
            "#!/bin/sh\n# prism:name=Hello world\n# prism:description=Print a greeting\n# prism:keywords=greet, demo\nprintf hello\n",
        );
        let nested = directory.0.join("nested");
        fs::create_dir(&nested).expect("create nested directory");
        let nested_script = TestDirectory(nested.clone());
        nested_script.executable("hidden.sh", "#!/bin/sh\nprintf hidden\n");

        let registry = ScriptCommandRegistry::default();
        let result = refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()])
            .expect("refresh scripts");

        assert_eq!(result.commands.len(), 1);
        assert_eq!(result.commands[0].title, "Hello world");
        assert!(result.commands[0].id.starts_with("sc_"));
        assert!(!result.commands[0].id.contains("hello"));
        std::mem::forget(nested_script);
    }

    #[cfg(unix)]
    #[test]
    fn refresh_rejects_symlinks_and_non_executable_files() {
        use std::os::unix::fs::symlink;

        let directory = TestDirectory::new();
        let executable = directory.executable("allowed.sh", "#!/bin/sh\nexit 0\n");
        fs::write(directory.0.join("not-executable.sh"), "#!/bin/sh\nexit 0\n")
            .expect("write non-executable file");
        symlink(&executable, directory.0.join("alias.sh")).expect("create symlink");

        let registry = ScriptCommandRegistry::default();
        let result = refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()])
            .expect("refresh scripts");
        assert_eq!(result.commands.len(), 1);
        assert_eq!(result.skipped_entries, 2);
    }

    #[cfg(unix)]
    #[test]
    fn execution_requires_a_current_registered_path_and_bounds_output() {
        let directory = TestDirectory::new();
        let script_path = directory.executable(
            "output.sh",
            "#!/bin/sh\nprintf 'hello'\nprintf 'problem' >&2\n",
        );
        let registry = ScriptCommandRegistry::default();
        let refresh = refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()])
            .expect("refresh scripts");
        let registered = resolve_registered_script(&registry, &refresh.commands[0].id)
            .expect("resolve registered script");
        let result = execute_registered_script(registered.clone()).expect("execute script");
        assert!(result.succeeded);
        assert_eq!(result.stdout, "hello");
        assert_eq!(result.stderr, "problem");

        fs::remove_file(script_path).expect("remove script");
        assert!(execute_registered_script(registered).is_err());
        assert!(resolve_registered_script(&registry, "sc_ffffffffffffffff").is_err());
    }

    #[cfg(unix)]
    fn fixture(source: &str) -> (TestDirectory, RegisteredScript) {
        let directory = TestDirectory::new();
        directory.executable("fixture.sh", source);
        let registry = ScriptCommandRegistry::default();
        let refresh =
            refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()]).unwrap();
        let script = resolve_registered_script(&registry, &refresh.commands[0].id).unwrap();
        (directory, script)
    }

    #[cfg(unix)]
    #[test]
    fn parses_arguments_and_passes_literal_values_without_shell_interpolation() {
        let (_directory, script) = fixture(
            r#"#!/bin/sh
# @raycast.argument1 {"type":"text","placeholder":"Target"}
# prism:argument2={"type":"text","placeholder":"Optional","optional":true}
printf '%s|%s|%s' "$#" "$1" "$2"
"#,
        );
        assert_eq!(script.summary.arguments.len(), 2);
        assert!(validate_arguments(&script.summary, vec![]).is_err());
        assert!(
            validate_arguments(&script.summary, vec!["x".into(), "y".into(), "z".into()]).is_err()
        );
        assert!(validate_arguments(&script.summary, vec!["x\0".into()]).is_err());
        let args =
            validate_arguments(&script.summary, vec!["hello; $(echo injected)".into()]).unwrap();
        let result = execute_script(script, args, &ScriptRun::default(), SCRIPT_TIMEOUT).unwrap();
        assert_eq!(result.stdout, "2|hello; $(echo injected)|");
    }

    #[cfg(unix)]
    #[test]
    fn validates_dropdown_encoding_and_rejects_malformed_or_gapped_metadata() {
        let (_directory, script) = fixture(
            r#"#!/bin/sh
# prism:argument1={"type":"dropdown","placeholder":"Choice","percentEncoded":true,"data":[{"title":"Korean","value":"한 글&"}]}
exit 0
"#,
        );
        assert!(validate_arguments(&script.summary, vec!["unlisted".into()]).is_err());
        assert_eq!(
            validate_arguments(&script.summary, vec!["한 글&".into()]).unwrap(),
            vec!["%ED%95%9C%20%EA%B8%80%26"]
        );
        for metadata in [
            r#"# prism:argument1={bad}"#,
            r#"# prism:argument2={"type":"text","placeholder":"Gap"}"#,
            r#"# prism:argument1={"type":"file","placeholder":"Unsupported"}"#,
        ] {
            let (_directory, script) = fixture(&format!("#!/bin/sh\n{metadata}\nexit 0\n"));
            assert!(script.summary.argument_error.is_some());
            assert!(validate_arguments(&script.summary, vec![]).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_and_timeout_kill_descendants_and_keep_output() {
        for cancel in [true, false] {
            let (directory, script) = fixture("#!/bin/sh\nprintf started\nprintf problem >&2\n(sleep 2; printf leaked > escaped) &\nwait\n");
            let run = Arc::new(ScriptRun::default());
            let worker = Arc::clone(&run);
            let task = thread::spawn(move || {
                execute_script(
                    script,
                    vec![],
                    &worker,
                    Duration::from_secs(if cancel { 5 } else { 1 }),
                )
                .unwrap()
            });
            let deadline = Instant::now() + Duration::from_secs(4);
            while run.stdout.snapshot().0.is_empty() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(5));
            }
            if cancel {
                run.cancel.store(true, Ordering::Release);
            }
            let result = task.join().unwrap();
            assert_eq!(result.cancelled, cancel);
            assert_eq!(result.timed_out, !cancel);
            assert!(!result.succeeded);
            assert_eq!(result.stdout, "started");
            assert_eq!(result.stderr, "problem");
            thread::sleep(Duration::from_millis(2100));
            assert!(
                !directory.0.join("escaped").exists(),
                "descendant survived termination"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn drains_and_bounds_both_streams_and_reports_nonzero_exit() {
        let (_directory, script) =
            fixture("#!/bin/sh\nhead -c 100000 /dev/zero\nhead -c 100000 /dev/zero >&2\nexit 7\n");
        let result = execute_registered_script(script).unwrap();
        assert_eq!(result.exit_code, Some(7));
        assert!(!result.succeeded);
        assert_eq!(result.stdout.len(), MAX_CAPTURE_BYTES);
        assert_eq!(result.stderr.len(), MAX_CAPTURE_BYTES);
        assert!(result.stdout_truncated && result.stderr_truncated);
    }

    #[cfg(unix)]
    #[test]
    fn run_registry_limits_concurrency_and_publishes_cancellation() {
        let directory = TestDirectory::new();
        for index in 0..5 {
            directory.executable(
                &format!("wait{index}.sh"),
                "#!/bin/sh\nprintf ready\nsleep 8\n",
            );
        }
        let registry = ScriptCommandRegistry::default();
        let refresh =
            refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()]).unwrap();
        assert!(
            registry.runs.lock().unwrap().is_empty(),
            "discovery must never execute"
        );
        assert!(resolve_run(&registry, "../../wait.sh").is_err());
        let runs: Vec<_> = refresh
            .commands
            .iter()
            .take(4)
            .map(|script| start_registered_run(&registry, &script.id, vec![]).unwrap())
            .collect();
        assert!(start_registered_run(&registry, &refresh.commands[4].id, vec![]).is_err());
        for snapshot in &runs {
            let run = resolve_run(&registry, &snapshot.run_id).unwrap();
            run.cancel.store(true, Ordering::Release);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        for snapshot in runs {
            let run = resolve_run(&registry, &snapshot.run_id).unwrap();
            while run.completion.lock().unwrap().is_none() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(5));
            }
            let finished = run_snapshot(snapshot.run_id, &run).unwrap();
            assert_eq!(finished.state, "cancelled");
            assert!(finished.result.unwrap().cancelled);
        }
    }

    #[cfg(unix)]
    #[test]
    fn run_listing_reattaches_after_refresh_without_execution_or_arguments() {
        let directory = TestDirectory::new();
        directory.executable("recover.sh", "#!/bin/sh\nprintf ready\nsleep 8\n");
        let registry = ScriptCommandRegistry::default();
        let directories = vec![directory.0.to_string_lossy().into_owned()];
        let first = refresh_registry(&registry, directories.clone()).unwrap();
        let script_id = &first.commands[0].id;
        let snapshot = start_registered_run(&registry, script_id, vec![]).unwrap();
        assert!(start_registered_run(&registry, script_id, vec![]).is_err());
        let refreshed = refresh_registry(&registry, directories).unwrap();
        assert_eq!(&refreshed.commands[0].id, script_id);
        let listed = list_registered_runs(&registry).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].run_id, snapshot.run_id);
        assert_eq!(&listed[0].script_id, script_id);
        let serialized = serde_json::to_value(&listed[0]).unwrap();
        assert!(serialized.get("args").is_none());
        assert!(serialized.get("path").is_none());
        let run = resolve_run(&registry, &snapshot.run_id).unwrap();
        run.cancel.store(true, Ordering::Release);
        let deadline = Instant::now() + Duration::from_secs(5);
        while run.completion.lock().unwrap().is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            list_registered_runs(&registry).unwrap()[0].state,
            "cancelled"
        );
        assert_eq!(
            registry.next_run_id.load(Ordering::Relaxed),
            1,
            "reattachment must never execute again"
        );
    }

    fn history_run(registry: &ScriptCommandRegistry, sequence: u64) -> ScriptRun {
        ScriptRun {
            script_id: "sc_0000000000000001".into(),
            run_id: format!("sr_{sequence:016x}"),
            started_at_ms: 1_000,
            history: Some(Arc::clone(&registry.history)),
            ..ScriptRun::default()
        }
    }

    #[test]
    fn restart_marks_inflight_interrupted_preserves_output_and_never_executes() {
        let directory = TestDirectory::new();
        let path = directory.0.join("history.json");
        let registry = ScriptCommandRegistry::default();
        registry.initialize(path.clone()).unwrap();
        let run = history_run(&registry, 7);
        run.stdout.append(b"checkpoint output");
        run.stderr.append(b"warning");
        checkpoint_run(&run).unwrap();
        drop(registry);
        let restarted = ScriptCommandRegistry::default();
        restarted.initialize(path.clone()).unwrap();
        let snapshots = list_registered_runs(&restarted).unwrap();
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].state, "interrupted");
        assert_eq!(snapshots[0].stdout, "checkpoint output");
        assert_eq!(snapshots[0].stderr, "warning");
        assert!(snapshots[0].result.is_none());
        assert_eq!(snapshots[0].started_at_ms, 1_000);
        assert_eq!(restarted.next_run_id.load(Ordering::Relaxed), 7);
        assert!(restarted.state.read().unwrap().scripts.is_empty());
        assert!(restarted.runs.lock().unwrap().values().all(|run| run
            .completion
            .lock()
            .unwrap()
            .is_some()));
        let saved: HistoryFile = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(
            saved.runs[0].state, "interrupted",
            "recovery itself is durable"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn identities_survive_restart_and_changed_discovery_order() {
        let directory = TestDirectory::new();
        directory.executable("zebra.sh", "#!/bin/sh\nexit 0\n");
        let history_directory = TestDirectory::new();
        let path = history_directory.0.join("history.json");
        let registry = ScriptCommandRegistry::default();
        registry.initialize(path.clone()).unwrap();
        let roots = vec![directory.0.to_string_lossy().into_owned()];
        let first = refresh_registry(&registry, roots.clone()).unwrap();
        let original_id = first.commands[0].id.clone();
        drop(registry);
        directory.executable("aardvark.sh", "#!/bin/sh\nexit 0\n");
        let restarted = ScriptCommandRegistry::default();
        restarted.initialize(path).unwrap();
        let fresh = refresh_registry(&restarted, roots).unwrap();
        assert_eq!(fresh.commands[1].id, original_id);
        assert_ne!(fresh.commands[0].id, original_id);
        assert!(list_registered_runs(&restarted).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn timeout_metadata_has_safe_default_and_rejects_out_of_range_values() {
        for (value, expected) in [
            ("1", Some(1)),
            ("3600", Some(3600)),
            ("0", None),
            ("3601", None),
            ("-1", None),
            ("1.5", None),
            ("never", None),
        ] {
            let (_directory, script) =
                fixture(&format!("#!/bin/sh\n# prism:timeout={value}\nexit 0\n"));
            assert_eq!(
                script.summary.argument_error.is_none(),
                expected.is_some(),
                "{value}"
            );
            if let Some(expected) = expected {
                assert_eq!(script.summary.timeout_seconds, Some(expected));
            }
        }
        let (_directory, script) = fixture("#!/bin/sh\nexit 0\n");
        assert_eq!(
            script.summary.timeout_seconds,
            Some(DEFAULT_TIMEOUT_SECONDS)
        );
    }

    #[cfg(unix)]
    #[test]
    fn configured_timeout_is_enforced_and_terminal_result_is_durable() {
        let directory = TestDirectory::new();
        directory.executable(
            "timeout.sh",
            // Leave headroom for macOS executable startup under the parallel
            // suite, while still enforcing a timeout before the sleep finishes.
            "#!/bin/sh\n# prism:timeout=3\nprintf before-timeout\nsleep 8\n",
        );
        let history_directory = TestDirectory::new();
        let path = history_directory.0.join("history.json");
        let registry = ScriptCommandRegistry::default();
        registry.initialize(path.clone()).unwrap();
        let scripts =
            refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()]).unwrap();
        let initial = start_registered_run(&registry, &scripts.commands[0].id, vec![]).unwrap();
        let run = resolve_run(&registry, &initial.run_id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while run_snapshot(initial.run_id.clone(), &run).unwrap().state == "running"
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(10));
        }
        let snapshot = run_snapshot(initial.run_id, &run).unwrap();
        assert_eq!(snapshot.state, "timedOut");
        assert!(snapshot.persistence_error.is_none());
        assert_eq!(snapshot.timeout_seconds, 3);
        assert!(snapshot.result.as_ref().unwrap().timed_out);
        assert_eq!(
            snapshot.stdout, "before-timeout",
            "live output: {snapshot:?}"
        );
        let restarted = ScriptCommandRegistry::default();
        restarted.initialize(path).unwrap();
        let restored = list_registered_runs(&restarted).unwrap();
        assert_eq!(restored[0].state, "timedOut");
        assert_eq!(restored[0].stdout, "before-timeout");
        assert_eq!(
            restored[0].result.as_ref().unwrap().stdout,
            "before-timeout"
        );
    }

    #[cfg(unix)]
    #[test]
    fn password_arguments_and_echoed_output_are_never_persisted() {
        let directory = TestDirectory::new();
        directory.executable("secret.sh", "#!/bin/sh\n# prism:argument1={\"type\":\"password\",\"placeholder\":\"Secret\",\"percentEncoded\":true}\nprintf '%s' \"$1\"\nprintf '%s' \"$1\" >&2\n");
        let history_directory = TestDirectory::new();
        let path = history_directory.0.join("history.json");
        let registry = ScriptCommandRegistry::default();
        registry.initialize(path.clone()).unwrap();
        let scripts =
            refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()]).unwrap();
        let initial = start_registered_run(
            &registry,
            &scripts.commands[0].id,
            vec!["secret value!".into()],
        )
        .unwrap();
        let run = resolve_run(&registry, &initial.run_id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while run_snapshot(initial.run_id.clone(), &run).unwrap().state == "running"
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            run_snapshot(initial.run_id, &run).unwrap().stdout,
            "secret%20value!"
        );
        let bytes = fs::read_to_string(&path).unwrap();
        assert!(!bytes.contains("secret value!"));
        assert!(!bytes.contains("secret%20value!"));
        assert!(!bytes.contains("\"args\""));
        let restarted = ScriptCommandRegistry::default();
        restarted.initialize(path).unwrap();
        let snapshots = list_registered_runs(&restarted).unwrap();
        assert_eq!(snapshots[0].state, "success");
        assert!(snapshots[0].output_withheld);
        assert!(snapshots[0].stdout.is_empty() && snapshots[0].stderr.is_empty());
        assert!(snapshots[0].result.as_ref().unwrap().stdout.is_empty());
    }

    #[test]
    fn retention_keeps_active_runs_and_bounds_saved_streams() {
        let directory = TestDirectory::new();
        let registry = ScriptCommandRegistry::default();
        let path = directory.0.join("history.json");
        registry.initialize(path.clone()).unwrap();
        let active = history_run(&registry, 1);
        checkpoint_run(&active).unwrap();
        for sequence in 2..=40 {
            let run = history_run(&registry, sequence);
            run.stdout.append(&vec![b'x'; MAX_CAPTURE_BYTES + 99]);
            complete_run(&run, Err("fixture terminal failure".into()));
        }
        let saved: HistoryFile = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved.runs.len(), MAX_RUNS);
        assert_eq!(saved.runs[0].state, "running");
        assert_eq!(saved.runs[0].run_id, active.run_id);
        assert!(saved.runs[1..]
            .iter()
            .all(|run| run.stdout.len() == MAX_CAPTURE_BYTES && run.stdout_truncated));
        assert!((fs::metadata(path).unwrap().len()) < MAX_HISTORY_FILE_BYTES);
    }

    #[cfg(unix)]
    #[test]
    fn initial_checkpoint_failure_never_launches_and_save_retry_never_executes() {
        let directory = TestDirectory::new();
        directory.executable("marker.sh", "#!/bin/sh\nprintf ran > executed\n");
        let history_directory = TestDirectory::new();
        let path = history_directory.0.join("history.json");
        let registry = ScriptCommandRegistry::default();
        registry.initialize(path.clone()).unwrap();
        let scripts =
            refresh_registry(&registry, vec![directory.0.to_string_lossy().into_owned()]).unwrap();
        fs::create_dir(path.with_extension("json.tmp")).unwrap();
        assert!(start_registered_run(&registry, &scripts.commands[0].id, vec![]).is_err());
        assert!(!directory.0.join("executed").exists());
        assert!(list_registered_runs(&registry).unwrap().is_empty());
        let run = history_run(&registry, 2);
        complete_run(&run, Err("fixture failure".into()));
        assert!(run_snapshot(run.run_id.clone(), &run)
            .unwrap()
            .persistence_error
            .is_some());
        fs::remove_dir(path.with_extension("json.tmp")).unwrap();
        save_run_progress(&run);
        assert!(run_snapshot(run.run_id.clone(), &run)
            .unwrap()
            .persistence_error
            .is_none());
        assert!(!directory.0.join("executed").exists());
        let saved: HistoryFile = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(saved.runs.len(), 1);
        assert_eq!(saved.runs[0].state, "failure");
    }

    #[test]
    fn corrupt_or_oversized_history_is_preserved_and_initialization_fails() {
        let directory = TestDirectory::new();
        let path = directory.0.join("history.json");
        fs::write(&path, b"{broken").unwrap();
        let registry = ScriptCommandRegistry::default();
        assert!(registry.initialize(path.clone()).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"{broken");
        assert!(registry.history.lock().unwrap().path.is_none());
        let file = fs::File::create(&path).unwrap();
        file.set_len(MAX_HISTORY_FILE_BYTES + 1).unwrap();
        assert!(registry.initialize(path.clone()).is_err());
        assert_eq!(
            fs::metadata(path).unwrap().len(),
            MAX_HISTORY_FILE_BYTES + 1
        );
    }

    #[test]
    fn bounded_output_keeps_only_the_configured_prefix() {
        let output = BoundedOutput::new();
        output.append(&vec![b'x'; MAX_CAPTURE_BYTES + 17]);
        let (captured, truncated) = output.snapshot();
        assert_eq!(captured.len(), MAX_CAPTURE_BYTES);
        assert!(truncated);
    }
}
