pub mod modifier;
use modifier::Binding;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    fs, io,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_global_shortcut::{Modifiers, Shortcut, ShortcutState};

const DEFAULT_ACCELERATOR: &str = "CommandOrControl+Shift+Space";
const SETTINGS_FILE_NAME: &str = "global-shortcut-v1.json";
const COMMAND_SETTINGS_FILE_NAME: &str = "command-shortcuts-v1.json";
const SETTINGS_VERSION: u8 = 1;
const INACTIVE_SHORTCUT_ID: u64 = 0;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GlobalShortcutIssue {
    code: String,
    message: String,
}

impl GlobalShortcutIssue {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GlobalShortcutSetting {
    accelerator: String,
    default_accelerator: String,
    is_default: bool,
    registered: bool,
    issue: Option<GlobalShortcutIssue>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GlobalShortcutCommandError {
    code: String,
    message: String,
    attempted_accelerator: Option<String>,
    active: GlobalShortcutSetting,
}

type ShortcutCommandResult = Result<GlobalShortcutSetting, Box<GlobalShortcutCommandError>>;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandShortcutSetting {
    command_id: String,
    shortcut: String,
    registered: bool,
    issue: Option<GlobalShortcutIssue>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandShortcutError {
    code: String,
    message: String,
    command_id: String,
    attempted_shortcut: Option<String>,
    active: Option<CommandShortcutSetting>,
}

type CommandShortcutResult = Result<CommandShortcutSetting, Box<CommandShortcutError>>;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct PersistedShortcut {
    version: u8,
    accelerator: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct PersistedCommandShortcuts {
    version: u8,
    shortcuts: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
struct ParsedShortcut {
    accelerator: String,
    shortcut: Binding,
}

#[derive(Debug)]
struct RuntimeState {
    active: ParsedShortcut,
    registered: bool,
    issue: Option<GlobalShortcutIssue>,
    desired_commands: BTreeMap<String, String>,
    commands: HashMap<String, ParsedShortcut>,
    command_issues: HashMap<String, GlobalShortcutIssue>,
}

impl RuntimeState {
    fn setting(&self, default_accelerator: &str) -> GlobalShortcutSetting {
        GlobalShortcutSetting {
            accelerator: self.active.accelerator.clone(),
            default_accelerator: default_accelerator.to_string(),
            is_default: self.active.accelerator == default_accelerator,
            registered: self.registered,
            issue: self.issue.clone(),
        }
    }

    fn activate(&mut self, shortcut: ParsedShortcut) {
        self.active = shortcut;
        self.registered = true;
        self.issue = None;
    }

    fn command_setting(&self, command_id: &str) -> Option<CommandShortcutSetting> {
        self.desired_commands.get(command_id).map(|desired| {
            let active = self.commands.get(command_id);
            CommandShortcutSetting {
                command_id: command_id.to_string(),
                shortcut: active
                    .map(|binding| binding.accelerator.clone())
                    .unwrap_or_else(|| desired.clone()),
                registered: active.is_some(),
                issue: self.command_issues.get(command_id).cloned(),
            }
        })
    }

    fn command_settings(&self) -> Vec<CommandShortcutSetting> {
        self.desired_commands
            .keys()
            .filter_map(|command_id| self.command_setting(command_id))
            .collect()
    }
}

pub struct GlobalShortcutManager {
    active_id: Arc<AtomicU64>,
    command_dispatch: Arc<RwLock<HashMap<u64, String>>>,
    default: ParsedShortcut,
    settings_path: PathBuf,
    command_settings_path: PathBuf,
    state: Mutex<RuntimeState>,
}

impl GlobalShortcutManager {
    pub(crate) fn refresh_modifier_permissions(&self, app: &AppHandle, granted: bool) {
        if granted {
            // Restore a saved double-tap launcher after startup permission failure.
            if let Ok(Some(saved)) = load_persisted(&self.settings_path) {
                if let Ok(candidate) = parse_shortcut(&saved) {
                    if matches!(candidate.shortcut, Binding::Double(_)) {
                        let _ = self.replace(app, candidate, Persistence::Save);
                    }
                }
            }
        }
        if let Ok(mut state) = self.state.lock() {
            if !granted && matches!(state.active.shortcut, Binding::Double(_)) {
                let _ = state.active.shortcut.unregister(app);
                self.active_id
                    .store(INACTIVE_SHORTCUT_ID, Ordering::Release);
                state.registered = false;
                state.issue = Some(GlobalShortcutIssue::new(
                    "permissionRequired",
                    "Modifier double-tap shortcuts require Accessibility access.",
                ));
            }
            let desired = state.desired_commands.clone();
            for (command, accelerator) in desired {
                let Ok(candidate) = parse_shortcut(&accelerator) else {
                    continue;
                };
                if !matches!(candidate.shortcut, Binding::Double(_)) {
                    continue;
                }
                if granted && !state.commands.contains_key(&command) {
                    match candidate.shortcut.register(app) {
                        Ok(()) => {
                            self.command_dispatch
                                .write()
                                .unwrap_or_else(|e| e.into_inner())
                                .insert(candidate.shortcut.id(), command.clone());
                            state.commands.insert(command.clone(), candidate);
                            state.command_issues.remove(&command);
                        }
                        Err(error) => {
                            state.command_issues.insert(
                                command.clone(),
                                GlobalShortcutIssue::new("registrationConflict", error),
                            );
                        }
                    }
                } else if !granted {
                    if let Some(active) = state.commands.remove(&command) {
                        let _ = active.shortcut.unregister(app);
                        self.command_dispatch
                            .write()
                            .unwrap_or_else(|e| e.into_inner())
                            .remove(&active.shortcut.id());
                    }
                    state.command_issues.insert(
                        command,
                        GlobalShortcutIssue::new(
                            "permissionRequired",
                            "Modifier double-tap shortcuts require Accessibility access.",
                        ),
                    );
                }
            }
            let _ = app.emit("prism:command-shortcuts-changed", state.command_settings());
            let _ = app.emit(
                "prism:global-shortcut-changed",
                state.setting(&self.default.accelerator),
            );
        }
    }

    pub(crate) fn prompt_shortcut_label(&self) -> Option<String> {
        self.prompt_shortcut().map(|s| dictation_shortcut_display(&s))
    }
    fn prompt_shortcut(&self) -> Option<String> {
        self.state.lock().ok()?.command_settings().into_iter().find(|s| s.command_id == "prism:dictation-prompt" && s.registered).map(|s| s.shortcut)
    }
    pub(crate) fn prompt_double_modifier(&self) -> Option<u32> {
        let shortcut = self.prompt_shortcut()?;
        modifier::NAMES.iter().position(|n| n.eq_ignore_ascii_case(&shortcut)).map(|k| k as u32)
    }
    fn dictation_shortcut(&self) -> Option<String> {
        self.state
            .lock()
            .ok()?
            .command_settings()
            .into_iter()
            .find(|setting| setting.command_id == "prism:dictation" && setting.registered)
            .map(|setting| setting.shortcut)
    }
    pub(crate) fn dictation_shortcut_label(&self) -> Option<String> {
        self.dictation_shortcut()
            .map(|shortcut| dictation_shortcut_display(&shortcut))
    }

    pub(crate) fn dictation_double_modifier(&self) -> Option<u32> {
        let shortcut = self.dictation_shortcut()?;
        modifier::NAMES
            .iter()
            .position(|name| name.eq_ignore_ascii_case(&shortcut))
            .map(|kind| kind as u32)
    }
}
fn dictation_shortcut_display(shortcut: &str) -> String {
    if let Some(kind) = modifier::NAMES
        .iter()
        .position(|name| name.eq_ignore_ascii_case(shortcut))
    {
        let key = ["⌃", "⌥", "⇧", "⌘"][kind];
        return format!("{key} {key}");
    }
    shortcut
        .split('+')
        .map(|part| match part.to_ascii_lowercase().as_str() {
            "commandorcontrol" | "super" | "meta" | "command" => "⌘".into(),
            "control" | "ctrl" => "⌃".into(),
            "alt" | "option" => "⌥".into(),
            "shift" => "⇧".into(),
            "space" => "Space".into(),
            "enter" => "Return".into(),
            "escape" => "Esc".into(),
            "comma" => ",".into(),
            "period" => ".".into(),
            "slash" => "/".into(),
            _ => part
                .strip_prefix("Key")
                .or_else(|| part.strip_prefix("Digit"))
                .unwrap_or(part)
                .to_owned(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug)]
enum FileSnapshot {
    Missing,
    Present(Vec<u8>),
}

pub fn install(
    app: &mut tauri::App,
    on_palette_trigger: fn(&AppHandle),
    on_command_trigger: fn(&AppHandle, &str),
) -> Result<(), Box<dyn std::error::Error>> {
    let active_id = Arc::new(AtomicU64::new(INACTIVE_SHORTCUT_ID));
    let handler_active_id = Arc::clone(&active_id);
    let command_dispatch = Arc::new(RwLock::new(HashMap::<u64, String>::new()));
    let handler_command_dispatch = Arc::clone(&command_dispatch);
    app.handle().plugin(
        tauri_plugin_global_shortcut::Builder::new()
            .with_handler(move |app, _, event| {
                if event.state() != ShortcutState::Pressed {
                    return;
                }
                if event.id as u64 == handler_active_id.load(Ordering::Acquire) {
                    on_palette_trigger(app);
                    return;
                }
                let command_id = handler_command_dispatch
                    .read()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .get(&(event.id as u64))
                    .cloned();
                if let Some(command_id) = command_id {
                    on_command_trigger(app, &command_id);
                }
            })
            .build(),
    )?;

    let modifier_app = app.handle().clone();
    let modifier_active = Arc::clone(&active_id);
    let modifier_commands = Arc::clone(&command_dispatch);
    modifier::install(move |id| {
        let app = modifier_app.clone();
        let active = Arc::clone(&modifier_active);
        let commands = Arc::clone(&modifier_commands);
        let _ = modifier_app.run_on_main_thread(move || {
            if id == active.load(Ordering::Acquire) {
                on_palette_trigger(&app);
                return;
            }
            let command = commands
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .get(&id)
                .cloned();
            if let Some(command) = command {
                on_command_trigger(&app, &command);
            }
        });
    });

    let default = parse_shortcut(DEFAULT_ACCELERATOR)
        .expect("Prism's built-in global shortcut must always be valid");
    let settings_path = app.path().app_config_dir()?.join(SETTINGS_FILE_NAME);
    let command_settings_path = app
        .path()
        .app_config_dir()?
        .join(COMMAND_SETTINGS_FILE_NAME);
    let (preferred, mut issue) = match load_persisted(&settings_path) {
        Ok(Some(accelerator)) => match parse_shortcut(&accelerator) {
            Ok(shortcut) => (shortcut, None),
            Err(message) => (
                default.clone(),
                Some(GlobalShortcutIssue::new(
                    "invalidPersistedShortcut",
                    format!("The saved global shortcut is invalid; Prism used the default instead. {message}"),
                )),
            ),
        },
        Ok(None) => (default.clone(), None),
        Err(error) => (
            default.clone(),
            Some(GlobalShortcutIssue::new(
                "persistenceFailed",
                format!("Prism could not read the saved global shortcut and used the default instead: {error}"),
            )),
        ),
    };

    let mut active = preferred.clone();
    let registration = preferred.shortcut.register(app.handle());
    let mut registered = registration.is_ok();
    if !registered && preferred.accelerator != default.accelerator {
        issue = Some(GlobalShortcutIssue::new(
            "registrationConflict",
            format!(
                "The saved shortcut {} is unavailable; Prism used {} for this session. {}",
                preferred.accelerator,
                default.accelerator,
                registration.err().unwrap_or_default()
            ),
        ));
        active = default.clone();
        registered = default.shortcut.register(app.handle()).is_ok();
    }

    if !registered {
        issue = Some(GlobalShortcutIssue::new(
            "registrationConflict",
            format!(
                "Prism could not register {} because it may already be in use.",
                active.accelerator
            ),
        ));
    } else {
        active_id.store(active.shortcut.id(), Ordering::Release);
    }

    let desired_commands = match load_persisted_commands(&command_settings_path) {
        Ok(shortcuts) => shortcuts,
        Err(error) => {
            eprintln!("Prism could not read command shortcuts: {error}");
            BTreeMap::new()
        }
    };
    let mut commands = HashMap::new();
    let mut command_issues = HashMap::new();
    {
        let mut dispatch = command_dispatch
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for (command_id, accelerator) in &desired_commands {
            let candidate = match parse_shortcut(accelerator) {
                Ok(candidate) => candidate,
                Err(message) => {
                    command_issues.insert(
                        command_id.clone(),
                        GlobalShortcutIssue::new("invalidPersistedShortcut", message),
                    );
                    continue;
                }
            };
            match candidate.shortcut.register(app.handle()) {
                Ok(()) => {
                    dispatch.insert(candidate.shortcut.id(), command_id.clone());
                    commands.insert(command_id.clone(), candidate);
                }
                Err(error) => {
                    command_issues.insert(
                        command_id.clone(),
                        GlobalShortcutIssue::new(
                            "registrationConflict",
                            format!("The saved shortcut {accelerator} is unavailable: {error}"),
                        ),
                    );
                }
            }
        }
    }

    let needs_recovery = !registered;
    app.manage(GlobalShortcutManager {
        active_id,
        command_dispatch,
        default,
        settings_path,
        command_settings_path,
        state: Mutex::new(RuntimeState {
            active,
            registered,
            issue,
            desired_commands,
            commands,
            command_issues,
        }),
    });
    if needs_recovery {
        set_recovery_mode(app.handle(), true, Some(on_palette_trigger));
    }
    Ok(())
}

#[tauri::command]
pub fn get_global_shortcut(manager: State<'_, GlobalShortcutManager>) -> ShortcutCommandResult {
    manager.current_setting()
}

#[tauri::command]
pub fn set_global_shortcut(
    app: AppHandle,
    manager: State<'_, GlobalShortcutManager>,
    accelerator: String,
) -> ShortcutCommandResult {
    let candidate = parse_shortcut(&accelerator).map_err(|message| {
        manager.error(
            "invalidShortcut",
            message,
            Some(accelerator.trim().to_string()),
        )
    })?;
    manager.replace(&app, candidate, Persistence::Save)
}

#[tauri::command]
pub fn reset_global_shortcut(
    app: AppHandle,
    manager: State<'_, GlobalShortcutManager>,
) -> ShortcutCommandResult {
    manager.replace(&app, manager.default.clone(), Persistence::Remove)
}

#[tauri::command]
pub fn get_command_shortcuts(
    manager: State<'_, GlobalShortcutManager>,
) -> Result<Vec<CommandShortcutSetting>, String> {
    manager
        .state
        .lock()
        .map(|state| state.command_settings())
        .map_err(|_| "Command shortcut state is temporarily unavailable.".to_string())
}

#[tauri::command]
pub fn set_command_shortcut(
    app: AppHandle,
    manager: State<'_, GlobalShortcutManager>,
    command_id: String,
    shortcut: String,
) -> CommandShortcutResult {
    let command_id = validate_command_id(&command_id).map_err(|message| {
        command_shortcut_error(
            "invalidCommandId",
            message,
            command_id.trim().to_string(),
            Some(shortcut.trim().to_string()),
            None,
        )
    })?;
    let candidate = parse_shortcut(&shortcut).map_err(|message| {
        manager.command_error(
            "invalidShortcut",
            message,
            &command_id,
            Some(shortcut.trim().to_string()),
        )
    })?;
    manager.set_command(&app, command_id, candidate)
}

#[tauri::command]
pub fn remove_command_shortcut(
    app: AppHandle,
    manager: State<'_, GlobalShortcutManager>,
    command_id: String,
) -> Result<(), Box<CommandShortcutError>> {
    let command_id = validate_command_id(&command_id).map_err(|message| {
        command_shortcut_error(
            "invalidCommandId",
            message,
            command_id.trim().to_string(),
            None,
            None,
        )
    })?;
    manager.remove_command(&app, &command_id)
}

#[derive(Clone, Copy)]
enum Persistence {
    Save,
    Remove,
}

impl GlobalShortcutManager {
    pub(crate) fn is_registered(&self) -> bool {
        self.state
            .lock()
            .map(|state| state.registered)
            .unwrap_or(false)
    }

    fn current_setting(&self) -> ShortcutCommandResult {
        self.state
            .lock()
            .map(|state| state.setting(&self.default.accelerator))
            .map_err(|_| self.unavailable_error(None))
    }

    fn replace(
        &self,
        app: &AppHandle,
        candidate: ParsedShortcut,
        persistence: Persistence,
    ) -> ShortcutCommandResult {
        let attempted = Some(candidate.accelerator.clone());
        let mut state = self
            .state
            .lock()
            .map_err(|_| self.unavailable_error(attempted.clone()))?;
        let previous_setting = state.setting(&self.default.accelerator);

        if state.registered && state.active.shortcut.id() == candidate.shortcut.id() {
            self.persist(&candidate, persistence).map_err(|error| {
                command_error(
                    "persistenceFailed",
                    format!("The shortcut is still active, but Prism could not save it: {error}"),
                    attempted.clone(),
                    previous_setting.clone(),
                )
            })?;
            state.issue = None;
            return Ok(state.setting(&self.default.accelerator));
        }

        let snapshot = snapshot_file(&self.settings_path).map_err(|error| {
            command_error(
                "persistenceFailed",
                format!("Prism could not prepare the shortcut settings update: {error}"),
                attempted.clone(),
                previous_setting.clone(),
            )
        })?;

        if let Err(error) = candidate.shortcut.register(app) {
            let issue = GlobalShortcutIssue::new(
                "registrationConflict",
                format!(
                    "Prism could not register {} because it may already be in use: {error}",
                    candidate.accelerator
                ),
            );
            state.issue = Some(issue.clone());
            return Err(command_error(
                issue.code,
                issue.message,
                attempted,
                state.setting(&self.default.accelerator),
            ));
        }

        if let Err(error) = self.persist(&candidate, persistence) {
            let cleanup_error = candidate
                .shortcut
                .unregister(app)
                .err()
                .map(|error| error.to_string());
            let restore_error = restore_file(&self.settings_path, &snapshot)
                .err()
                .map(|error| error.to_string());
            let message = rollback_message(
                format!("Prism could not save the new shortcut: {error}"),
                cleanup_error,
                restore_error,
            );
            state.issue = Some(GlobalShortcutIssue::new("persistenceFailed", &message));
            return Err(command_error(
                "persistenceFailed",
                message,
                attempted,
                state.setting(&self.default.accelerator),
            ));
        }

        if state.registered {
            if let Err(error) = state.active.shortcut.unregister(app) {
                let cleanup_error = candidate
                    .shortcut
                    .unregister(app)
                    .err()
                    .map(|error| error.to_string());
                let restore_error = restore_file(&self.settings_path, &snapshot)
                    .err()
                    .map(|error| error.to_string());
                let message = rollback_message(
                    format!(
                        "Prism could not replace the active shortcut; {} remains active: {error}",
                        state.active.accelerator
                    ),
                    cleanup_error,
                    restore_error,
                );
                state.issue = Some(GlobalShortcutIssue::new("registrationFailed", &message));
                return Err(command_error(
                    "registrationFailed",
                    message,
                    attempted,
                    state.setting(&self.default.accelerator),
                ));
            }
        }

        self.active_id
            .store(candidate.shortcut.id(), Ordering::Release);
        state.activate(candidate);
        set_recovery_mode(app, false, None);
        Ok(state.setting(&self.default.accelerator))
    }

    fn set_command(
        &self,
        app: &AppHandle,
        command_id: String,
        candidate: ParsedShortcut,
    ) -> CommandShortcutResult {
        let attempted = Some(candidate.accelerator.clone());
        let mut state = self.state.lock().map_err(|_| {
            command_shortcut_error(
                "stateUnavailable",
                "Command shortcut state is temporarily unavailable.",
                command_id.clone(),
                attempted.clone(),
                None,
            )
        })?;
        let previous = state.command_setting(&command_id);
        let mut next_desired = state.desired_commands.clone();
        next_desired.insert(command_id.clone(), candidate.accelerator.clone());

        if state
            .commands
            .get(&command_id)
            .is_some_and(|active| active.shortcut.id() == candidate.shortcut.id())
        {
            save_persisted_commands(&self.command_settings_path, &next_desired).map_err(
                |error| {
                    command_shortcut_error(
                        "persistenceFailed",
                        format!(
                            "The shortcut is still active, but Prism could not save it: {error}"
                        ),
                        command_id.clone(),
                        attempted.clone(),
                        previous.clone(),
                    )
                },
            )?;
            state.desired_commands = next_desired;
            state.command_issues.remove(&command_id);
            return state.command_setting(&command_id).ok_or_else(|| {
                command_shortcut_error(
                    "stateUnavailable",
                    "Prism could not read the updated command shortcut.",
                    command_id,
                    attempted,
                    previous,
                )
            });
        }

        let snapshot = snapshot_file(&self.command_settings_path).map_err(|error| {
            command_shortcut_error(
                "persistenceFailed",
                format!("Prism could not prepare the command shortcut update: {error}"),
                command_id.clone(),
                attempted.clone(),
                previous.clone(),
            )
        })?;

        if let Err(error) = candidate.shortcut.register(app) {
            return Err(command_shortcut_error(
                "registrationConflict",
                format!(
                    "Prism could not register {} because it may already be in use: {error}",
                    candidate.accelerator
                ),
                command_id,
                attempted,
                previous,
            ));
        }

        if let Err(error) = save_persisted_commands(&self.command_settings_path, &next_desired) {
            let cleanup_error = candidate
                .shortcut
                .unregister(app)
                .err()
                .map(|error| error.to_string());
            let restore_error = restore_file(&self.command_settings_path, &snapshot)
                .err()
                .map(|error| error.to_string());
            return Err(command_shortcut_error(
                "persistenceFailed",
                rollback_message(
                    format!("Prism could not save the command shortcut: {error}"),
                    cleanup_error,
                    restore_error,
                ),
                command_id,
                attempted,
                previous,
            ));
        }

        if let Some(active) = state.commands.get(&command_id) {
            if let Err(error) = active.shortcut.unregister(app) {
                let cleanup_error = candidate
                    .shortcut
                    .unregister(app)
                    .err()
                    .map(|error| error.to_string());
                let restore_error = restore_file(&self.command_settings_path, &snapshot)
                    .err()
                    .map(|error| error.to_string());
                return Err(command_shortcut_error(
                    "registrationFailed",
                    rollback_message(
                        format!(
                            "Prism could not replace the active command shortcut; {} remains active: {error}",
                            active.accelerator
                        ),
                        cleanup_error,
                        restore_error,
                    ),
                    command_id,
                    attempted,
                    previous,
                ));
            }
        }

        {
            let mut dispatch = self
                .command_dispatch
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(active) = state.commands.get(&command_id) {
                dispatch.remove(&active.shortcut.id());
            }
            dispatch.insert(candidate.shortcut.id(), command_id.clone());
        }
        state.desired_commands = next_desired;
        state.commands.insert(command_id.clone(), candidate);
        state.command_issues.remove(&command_id);
        state.command_setting(&command_id).ok_or_else(|| {
            command_shortcut_error(
                "stateUnavailable",
                "Prism could not read the updated command shortcut.",
                command_id,
                attempted,
                previous,
            )
        })
    }

    fn remove_command(
        &self,
        app: &AppHandle,
        command_id: &str,
    ) -> Result<(), Box<CommandShortcutError>> {
        let mut state = self.state.lock().map_err(|_| {
            command_shortcut_error(
                "stateUnavailable",
                "Command shortcut state is temporarily unavailable.",
                command_id,
                None,
                None,
            )
        })?;
        let previous = state.command_setting(command_id);
        if !state.desired_commands.contains_key(command_id) {
            return Ok(());
        }

        let mut next_desired = state.desired_commands.clone();
        next_desired.remove(command_id);
        let snapshot = snapshot_file(&self.command_settings_path).map_err(|error| {
            command_shortcut_error(
                "persistenceFailed",
                format!("Prism could not prepare the command shortcut removal: {error}"),
                command_id,
                None,
                previous.clone(),
            )
        })?;
        save_persisted_commands(&self.command_settings_path, &next_desired).map_err(|error| {
            command_shortcut_error(
                "persistenceFailed",
                format!(
                    "The shortcut remains active because Prism could not save its removal: {error}"
                ),
                command_id,
                None,
                previous.clone(),
            )
        })?;

        if let Some(active) = state.commands.get(command_id) {
            if let Err(error) = active.shortcut.unregister(app) {
                let restore_error = restore_file(&self.command_settings_path, &snapshot)
                    .err()
                    .map(|error| error.to_string());
                return Err(command_shortcut_error(
                    "registrationFailed",
                    rollback_message(
                        format!("Prism could not release the command shortcut: {error}"),
                        None,
                        restore_error,
                    ),
                    command_id,
                    None,
                    previous,
                ));
            }
        }

        if let Some(active) = state.commands.remove(command_id) {
            self.command_dispatch
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&active.shortcut.id());
        }
        state.desired_commands = next_desired;
        state.command_issues.remove(command_id);
        Ok(())
    }

    fn command_error(
        &self,
        code: impl Into<String>,
        message: impl Into<String>,
        command_id: &str,
        attempted_shortcut: Option<String>,
    ) -> Box<CommandShortcutError> {
        let active = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.command_setting(command_id));
        command_shortcut_error(code, message, command_id, attempted_shortcut, active)
    }

    fn persist(&self, shortcut: &ParsedShortcut, persistence: Persistence) -> io::Result<()> {
        match persistence {
            Persistence::Save => save_persisted(&self.settings_path, &shortcut.accelerator),
            Persistence::Remove => remove_persisted(&self.settings_path),
        }
    }

    fn error(
        &self,
        code: impl Into<String>,
        message: impl Into<String>,
        attempted_accelerator: Option<String>,
    ) -> Box<GlobalShortcutCommandError> {
        match self.current_setting() {
            Ok(active) => command_error(code, message, attempted_accelerator, active),
            Err(error) => error,
        }
    }

    fn unavailable_error(
        &self,
        attempted_accelerator: Option<String>,
    ) -> Box<GlobalShortcutCommandError> {
        let active = GlobalShortcutSetting {
            accelerator: self.default.accelerator.clone(),
            default_accelerator: self.default.accelerator.clone(),
            is_default: true,
            registered: false,
            issue: Some(GlobalShortcutIssue::new(
                "stateUnavailable",
                "The global shortcut state is unavailable.",
            )),
        };
        command_error(
            "stateUnavailable",
            "The global shortcut state is unavailable.",
            attempted_accelerator,
            active,
        )
    }
}

fn set_recovery_mode(app: &AppHandle, enabled: bool, show_palette: Option<fn(&AppHandle)>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.set_skip_taskbar(!enabled);
        if enabled {
            if let Some(show_palette) = show_palette {
                show_palette(app);
            } else {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        let policy = if enabled {
            tauri::ActivationPolicy::Regular
        } else {
            tauri::ActivationPolicy::Accessory
        };
        let _ = app.set_activation_policy(policy);
    }
}

fn command_shortcut_error(
    code: impl Into<String>,
    message: impl Into<String>,
    command_id: impl Into<String>,
    attempted_shortcut: Option<String>,
    active: Option<CommandShortcutSetting>,
) -> Box<CommandShortcutError> {
    Box::new(CommandShortcutError {
        code: code.into(),
        message: message.into(),
        command_id: command_id.into(),
        attempted_shortcut,
        active,
    })
}

fn command_error(
    code: impl Into<String>,
    message: impl Into<String>,
    attempted_accelerator: Option<String>,
    active: GlobalShortcutSetting,
) -> Box<GlobalShortcutCommandError> {
    Box::new(GlobalShortcutCommandError {
        code: code.into(),
        message: message.into(),
        attempted_accelerator,
        active,
    })
}

fn parse_shortcut(raw: &str) -> Result<ParsedShortcut, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Choose a shortcut before saving.".to_string());
    }
    if let Some(kind) = modifier::NAMES
        .iter()
        .position(|name| name.eq_ignore_ascii_case(trimmed))
    {
        return Ok(ParsedShortcut {
            accelerator: modifier::NAMES[kind].into(),
            shortcut: Binding::Double(kind as u32),
        });
    }
    let shortcut = trimmed
        .parse::<Shortcut>()
        .map_err(|error| format!("Prism could not understand that shortcut: {error}"))?;
    if shortcut
        .mods
        .intersection(Modifiers::SHIFT | Modifiers::CONTROL | Modifiers::ALT | Modifiers::SUPER)
        .is_empty()
    {
        return Err("Global shortcuts must include at least one modifier key.".to_string());
    }
    Ok(ParsedShortcut {
        accelerator: shortcut.to_string(),
        shortcut: Binding::Combination(shortcut),
    })
}

fn validate_command_id(raw: &str) -> Result<String, String> {
    let command_id = raw.trim();
    if command_id.is_empty() {
        return Err("Choose a command before assigning a shortcut.".to_string());
    }
    if command_id.len() > 256 {
        return Err("Command identifiers must be 256 bytes or fewer.".to_string());
    }
    if command_id.chars().any(char::is_control) {
        return Err("Command identifiers cannot contain control characters.".to_string());
    }
    Ok(command_id.to_string())
}

fn load_persisted(path: &Path) -> io::Result<Option<String>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let persisted = serde_json::from_slice::<PersistedShortcut>(&bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if persisted.version != SETTINGS_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported shortcut settings version {}.",
                persisted.version
            ),
        ));
    }
    Ok(Some(persisted.accelerator))
}

fn save_persisted(path: &Path, accelerator: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(&PersistedShortcut {
        version: SETTINGS_VERSION,
        accelerator: accelerator.to_string(),
    })
    .map_err(io::Error::other)?;
    fs::write(path, bytes)
}

fn load_persisted_commands(path: &Path) -> io::Result<BTreeMap<String, String>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
        Err(error) => return Err(error),
    };
    let persisted = serde_json::from_slice::<PersistedCommandShortcuts>(&bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if persisted.version != SETTINGS_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported command shortcut settings version {}.",
                persisted.version
            ),
        ));
    }
    Ok(persisted.shortcuts)
}

fn save_persisted_commands(path: &Path, shortcuts: &BTreeMap<String, String>) -> io::Result<()> {
    if shortcuts.is_empty() {
        return remove_persisted(path);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(&PersistedCommandShortcuts {
        version: SETTINGS_VERSION,
        shortcuts: shortcuts.clone(),
    })
    .map_err(io::Error::other)?;
    let temporary_path = path.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&temporary_path, bytes)?;
    match fs::rename(&temporary_path, path) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = fs::remove_file(&temporary_path);
            Err(error)
        }
    }
}

fn remove_persisted(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn snapshot_file(path: &Path) -> io::Result<FileSnapshot> {
    match fs::read(path) {
        Ok(bytes) => Ok(FileSnapshot::Present(bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(FileSnapshot::Missing),
        Err(error) => Err(error),
    }
}

fn restore_file(path: &Path, snapshot: &FileSnapshot) -> io::Result<()> {
    match snapshot {
        FileSnapshot::Missing => remove_persisted(path),
        FileSnapshot::Present(bytes) => {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(path, bytes)
        }
    }
}

fn rollback_message(
    message: String,
    cleanup_error: Option<String>,
    restore_error: Option<String>,
) -> String {
    let mut details = vec![message];
    if let Some(error) = cleanup_error {
        details.push(format!(
            "The candidate shortcut could not be released: {error}"
        ));
    }
    if let Some(error) = restore_error {
        details.push(format!(
            "The previous settings file could not be restored: {error}"
        ));
    }
    details.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_settings_path(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "prism-shortcut-{name}-{}-{nonce}.json",
            std::process::id()
        ))
    }

    #[test]
    fn parser_normalizes_aliases_and_requires_a_modifier() {
        let parsed = parse_shortcut("  Ctrl + Shift + K ").expect("parse shortcut");
        assert_eq!(parsed.accelerator, "shift+control+KeyK");
        assert!(parse_shortcut("K").is_err());
        assert!(parse_shortcut("Control+K+Shift").is_err());
    }

    #[test]
    fn modifier_double_taps_have_canonical_names_and_disjoint_dispatch_ids() {
        let mut ids = std::collections::HashSet::new();
        for name in modifier::NAMES {
            let parsed = parse_shortcut(&name.to_lowercase()).unwrap();
            assert_eq!(parsed.accelerator, name);
            assert!(parsed.shortcut.id() > u32::MAX as u64);
            assert!(ids.insert(parsed.shortcut.id()));
        }
        assert!(parse_shortcut("DoubleControl+KeyA").is_err());
        assert!(parse_shortcut("Control+Control").is_err());
        assert_eq!(dictation_shortcut_display("DoubleControl"), "⌃ ⌃");
    }

    #[test]
    fn double_taps_persist_for_launcher_and_arbitrary_commands() {
        let path = temporary_settings_path("double-tap-launcher");
        save_persisted(&path, "DoubleOption").unwrap();
        assert_eq!(load_persisted(&path).unwrap().unwrap(), "DoubleOption");
        remove_persisted(&path).unwrap();
        let path = temporary_settings_path("double-tap-commands");
        let bindings = BTreeMap::from([
            ("prism:dictation".into(), "DoubleControl".into()),
            ("app:fixture".into(), "DoubleShift".into()),
        ]);
        save_persisted_commands(&path, &bindings).unwrap();
        assert_eq!(load_persisted_commands(&path).unwrap(), bindings);
        remove_persisted(&path).unwrap();
    }

    #[test]
    fn platform_default_resolves_to_the_expected_modifier() {
        let parsed = parse_shortcut(DEFAULT_ACCELERATOR).expect("parse default");
        #[cfg(target_os = "macos")]
        assert_eq!(parsed.accelerator, "shift+super+Space");
        #[cfg(not(target_os = "macos"))]
        assert_eq!(parsed.accelerator, "shift+control+Space");
    }

    #[test]
    fn persisted_shortcut_round_trips_and_reset_removes_it() {
        let path = temporary_settings_path("round-trip");
        save_persisted(&path, "shift+control+KeyP").expect("save shortcut");
        assert_eq!(
            load_persisted(&path).expect("load shortcut").as_deref(),
            Some("shift+control+KeyP")
        );
        remove_persisted(&path).expect("remove shortcut");
        assert_eq!(load_persisted(&path).expect("load missing shortcut"), None);
    }

    #[test]
    fn persistence_snapshot_restores_previous_bytes() {
        let path = temporary_settings_path("snapshot");
        save_persisted(&path, "shift+control+KeyA").expect("save original");
        let snapshot = snapshot_file(&path).expect("snapshot shortcut");
        save_persisted(&path, "shift+control+KeyB").expect("save replacement");
        restore_file(&path, &snapshot).expect("restore shortcut");
        assert_eq!(
            load_persisted(&path).expect("load restored").as_deref(),
            Some("shift+control+KeyA")
        );
        remove_persisted(&path).expect("clean up shortcut");
    }

    #[test]
    fn runtime_state_activation_clears_issue_and_updates_public_state() {
        let default = parse_shortcut(DEFAULT_ACCELERATOR).expect("parse default");
        let replacement = parse_shortcut("Control+Alt+KeyP").expect("parse replacement");
        let mut state = RuntimeState {
            active: default.clone(),
            registered: false,
            issue: Some(GlobalShortcutIssue::new("registrationConflict", "busy")),
            desired_commands: BTreeMap::new(),
            commands: HashMap::new(),
            command_issues: HashMap::new(),
        };
        state.activate(replacement.clone());
        let public = state.setting(&default.accelerator);
        assert_eq!(public.accelerator, replacement.accelerator);
        assert!(public.registered);
        assert!(!public.is_default);
        assert!(public.issue.is_none());
    }

    #[test]
    fn dictation_hint_formats_the_registered_canonical_shortcut() {
        assert_eq!(dictation_shortcut_display("alt+KeyD"), "⌥ D");
        assert_eq!(dictation_shortcut_display("shift+super+Digit1"), "⇧ ⌘ 1");
        assert_eq!(dictation_shortcut_display("Control+Alt+Space"), "⌃ ⌥ Space");
    }

    #[test]
    fn persisted_command_shortcuts_round_trip_in_stable_order() {
        let path = temporary_settings_path("commands-round-trip");
        let shortcuts = BTreeMap::from([
            (
                "prism:settings".to_string(),
                "shift+super+Comma".to_string(),
            ),
            ("window:left".to_string(), "shift+control+KeyH".to_string()),
        ]);
        save_persisted_commands(&path, &shortcuts).expect("save command shortcuts");
        assert_eq!(
            load_persisted_commands(&path).expect("load command shortcuts"),
            shortcuts
        );
        remove_persisted(&path).expect("clean up command shortcuts");
    }

    #[test]
    fn command_settings_report_unavailable_persisted_bindings() {
        let default = parse_shortcut(DEFAULT_ACCELERATOR).expect("parse default");
        let mut state = RuntimeState {
            active: default,
            registered: true,
            issue: None,
            desired_commands: BTreeMap::from([(
                "demo:command".to_string(),
                "control+KeyD".to_string(),
            )]),
            commands: HashMap::new(),
            command_issues: HashMap::from([(
                "demo:command".to_string(),
                GlobalShortcutIssue::new("registrationConflict", "busy"),
            )]),
        };
        let setting = state.command_setting("demo:command").expect("setting");
        assert!(!setting.registered);
        assert_eq!(setting.shortcut, "control+KeyD");
        assert!(setting.issue.is_some());

        state.commands.insert(
            "demo:command".to_string(),
            parse_shortcut("Control+KeyD").expect("parse command"),
        );
        assert!(
            state
                .command_setting("demo:command")
                .expect("active setting")
                .registered
        );
    }

    #[test]
    fn command_ids_are_trimmed_and_reject_control_characters() {
        assert_eq!(
            validate_command_id("  prism:settings  ").unwrap(),
            "prism:settings"
        );
        assert!(validate_command_id("line\nbreak").is_err());
        assert!(validate_command_id("   ").is_err());
    }
}
