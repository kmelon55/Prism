//! Opt-in, local abbreviation expansion. The library remains the only text store.
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread::JoinHandle,
};
use tauri::{AppHandle, Emitter, Manager};

const MAX_KEYWORD: usize = 48;
const MAX_TEXT: usize = 128 * 1024;
// AX select-then-replace cannot yet be serialized with input in the target app.
// Keep the prototype unreachable, including previously persisted opt-ins, until
// native race acceptance is met. Keyword storage and manual snippet reuse work.
const AUTOMATIC_EXPANSION_AVAILABLE: bool = false;
fn validate_activation(enabled: bool) -> Result<(), String> {
    if enabled && !AUTOMATIC_EXPANSION_AVAILABLE {
        return Err(
            "Automatic expansion is unavailable in this build. Use Copy or Paste from Snippets."
                .into(),
        );
    }
    Ok(())
}
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    enabled: bool,
    excluded_apps: Vec<String>,
}
#[derive(Clone)]
struct Snippet {
    keyword: String,
    text: String,
}
#[derive(Default)]
struct Shared {
    reload: Mutex<()>,
    tap_failed: AtomicBool,
    config: Mutex<Config>,
    registry: Mutex<Arc<Vec<Snippet>>>,
    generation: AtomicU64,
    stop: AtomicBool,
    active: AtomicBool,
    error: Mutex<Option<String>>,
}
#[derive(Default)]
pub struct SnippetExpansion {
    shared: Arc<Shared>,
    thread: Mutex<Option<JoinHandle<()>>>,
    mutation: Mutex<()>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExpansionStatus {
    enabled: bool,
    supported: bool,
    active: bool,
    accessibility_granted: bool,
    input_monitoring_granted: bool,
    excluded_apps: Vec<String>,
    registered_count: usize,
    error: Option<String>,
}
pub fn valid_keyword(keyword: &str) -> bool {
    keyword.len() >= 2
        && keyword.len() <= MAX_KEYWORD
        && matches!(keyword.as_bytes()[0], b';' | b'!' | b'/' | b':')
        && keyword
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-;!/:".contains(&b))
}
fn starts_keyword(key: char) -> bool {
    matches!(key, ';' | '!' | '/' | ':')
}

fn registry(entries: Vec<crate::library::Entry>) -> Vec<Snippet> {
    let mut seen = HashSet::new();
    let mut duplicate = HashSet::new();
    let mut result = Vec::new();
    for entry in entries.into_iter().take(1000) {
        let Some(keyword) = entry.keyword else {
            continue;
        };
        if entry.kind != "snippet"
            || !valid_keyword(&keyword)
            || entry.value.is_empty()
            || entry.value.len() > MAX_TEXT
        {
            continue;
        }
        // Interactive templates require the existing library run flow.
        if ["{date}", "{time}", "{clipboard}"]
            .iter()
            .any(|token| entry.value.contains(token))
        {
            continue;
        }
        if !seen.insert(keyword.clone()) {
            duplicate.insert(keyword.clone());
        }
        result.push(Snippet {
            keyword,
            text: entry.value,
        });
    }
    result.retain(|entry| !duplicate.contains(&entry.keyword));
    result
}
pub fn refresh(app: &AppHandle) {
    let Some(state) = app.try_state::<SnippetExpansion>() else {
        return;
    };
    let _reload = state
        .shared
        .reload
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    // Invalidate before loading, including failed reloads: stale deleted text must never expand.
    state.shared.generation.fetch_add(1, Ordering::SeqCst);
    *state
        .shared
        .registry
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = Arc::new(Vec::new());
    match crate::library::snippet_entries(app) {
        Ok(entries) => {
            *state
                .shared
                .registry
                .lock()
                .unwrap_or_else(|e| e.into_inner()) = Arc::new(registry(entries));
        }
        Err(_) => {
            *state.shared.error.lock().unwrap_or_else(|e| e.into_inner()) =
                Some("Could not refresh saved snippets.".into());
        }
    }
    state.shared.generation.fetch_add(1, Ordering::SeqCst);
}
pub fn setup(app: &AppHandle) {
    if app.try_state::<SnippetExpansion>().is_some() {
        return;
    }
    let state = SnippetExpansion::default();
    if !AUTOMATIC_EXPANSION_AVAILABLE {
        app.manage(state);
        refresh(app);
        return;
    }
    if let Ok(dir) = app.path().app_data_dir() {
        let path = dir.join("snippet-expansion-v1.json");
        if path.exists() {
            match std::fs::read(&path)
                .ok()
                .filter(|bytes| bytes.len() <= 32 * 1024)
                .and_then(|bytes| serde_json::from_slice::<Config>(&bytes).ok())
            {
                Some(config) if valid_exclusions(&config.excluded_apps) => {
                    *state.shared.config.lock().unwrap() = config;
                }
                _ => {
                    *state.shared.error.lock().unwrap() =
                        Some("Could not read snippet settings. Expansion is off.".into());
                }
            }
        }
    }
    let shared = state.shared.clone();
    app.manage(state);
    refresh(app);
    let handle = std::thread::Builder::new()
        .name("prism-snippets".into())
        .spawn(move || {
            while !shared.stop.load(Ordering::Acquire) {
                #[cfg(target_os = "macos")]
                if !shared.tap_failed.load(Ordering::Acquire)
                    && shared
                        .config
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .enabled
                    && mac::permissions() == (true, true)
                {
                    mac::run(shared.clone());
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        });
    match handle {
        Ok(handle) => {
            *app.state::<SnippetExpansion>().thread.lock().unwrap() = Some(handle);
        }
        Err(_) => {
            *app.state::<SnippetExpansion>().shared.error.lock().unwrap() =
                Some("Could not start snippet expansion.".into());
        }
    }
}
pub fn shutdown(app: &AppHandle) {
    if let Some(state) = app.try_state::<SnippetExpansion>() {
        state.shared.stop.store(true, Ordering::SeqCst);
        state.shared.generation.fetch_add(1, Ordering::SeqCst);
        state.shared.active.store(false, Ordering::Release);
        if let Some(thread) = state
            .thread
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            let _ = thread.join();
        }
    }
}
fn valid_exclusions(apps: &[String]) -> bool {
    apps.len() <= 100
        && apps.iter().all(|app| {
            !app.is_empty()
                && app.len() <= 255
                && app
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b'_')
        })
}
#[tauri::command]
pub fn snippet_expansion_status(app: AppHandle) -> ExpansionStatus {
    let state = app.state::<SnippetExpansion>();
    let config = state
        .shared
        .config
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    #[cfg(target_os = "macos")]
    let (accessibility_granted, input_monitoring_granted) = mac::permissions();
    #[cfg(not(target_os = "macos"))]
    let (accessibility_granted, input_monitoring_granted) = (false, false);
    let registered_count = state
        .shared
        .registry
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .len();
    let error = state
        .shared
        .error
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    ExpansionStatus {
        enabled: AUTOMATIC_EXPANSION_AVAILABLE && config.enabled,
        supported: AUTOMATIC_EXPANSION_AVAILABLE && cfg!(target_os = "macos"),
        active: AUTOMATIC_EXPANSION_AVAILABLE
            && config.enabled
            && accessibility_granted
            && input_monitoring_granted
            && state.shared.active.load(Ordering::Acquire),
        accessibility_granted,
        input_monitoring_granted,
        excluded_apps: config.excluded_apps,
        registered_count,
        error,
    }
}
#[tauri::command]
pub fn snippet_expansion_configure(
    app: AppHandle,
    enabled: bool,
    excluded_apps: Vec<String>,
) -> Result<ExpansionStatus, String> {
    validate_activation(enabled)?;
    if !valid_exclusions(&excluded_apps) {
        return Err("Enter up to 100 application bundle IDs, one per line.".into());
    }
    let state = app.state::<SnippetExpansion>();
    let _lock = state
        .mutation
        .lock()
        .map_err(|_| "Snippet settings are busy.")?;
    let config = Config {
        enabled,
        excluded_apps,
    };
    // Disable immediately even if persisting the disabled preference subsequently fails.
    state.shared.generation.fetch_add(1, Ordering::SeqCst);
    state
        .shared
        .config
        .lock()
        .map_err(|_| "Snippet settings are busy.")?
        .enabled = false;
    // The tap lifecycle owns active; config.enabled already fences status and work.
    state.shared.tap_failed.store(false, Ordering::Release);
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|_| "Could not find snippet settings.")?;
    std::fs::create_dir_all(&dir).map_err(|_| "Could not create snippet settings.")?;
    let path = dir.join("snippet-expansion-v1.json");
    let temp = dir.join("snippet-expansion-v1.json.tmp");
    let bytes = serde_json::to_vec(&config).map_err(|_| "Could not encode snippet settings.")?;
    std::fs::write(&temp, bytes).map_err(|_| "Could not save snippet settings.")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "Could not protect snippet settings.")?;
    }
    std::fs::rename(temp, path).map_err(|_| "Could not save snippet settings.")?;
    *state
        .shared
        .config
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = config;
    *state.shared.error.lock().unwrap_or_else(|e| e.into_inner()) = None;
    state.shared.generation.fetch_add(1, Ordering::SeqCst);
    let _ = app.emit("prism:snippet-expansion-changed", ());
    Ok(snippet_expansion_status(app.clone()))
}
#[tauri::command]
pub fn snippet_expansion_request_permissions(app: AppHandle) -> ExpansionStatus {
    if !AUTOMATIC_EXPANSION_AVAILABLE {
        return snippet_expansion_status(app);
    }
    #[cfg(target_os = "macos")]
    {
        crate::window_management::request_accessibility_permission();
        mac::request_input_monitoring();
    }
    snippet_expansion_status(app)
}

/// Contains only registry indexes and a position, never the user's typed text.
#[derive(Default)]
struct Matcher {
    candidates: Vec<usize>,
    position: usize,
}
impl Matcher {
    fn reset(&mut self) {
        self.candidates.clear();
        self.position = 0;
    }
    fn feed(&mut self, key: char, snippets: &[Snippet], safe: bool) -> Option<usize> {
        if !safe {
            self.reset();
            return None;
        }
        if matches!(key, ' ' | '\t' | '\n') {
            let found = self
                .candidates
                .iter()
                .copied()
                .find(|index| snippets[*index].keyword.len() == self.position);
            self.reset();
            return found;
        }
        if !key.is_ascii() || self.position >= MAX_KEYWORD {
            self.reset();
        }
        if self.position > 0 {
            self.candidates.retain(|index| {
                snippets[*index].keyword.as_bytes().get(self.position) == Some(&(key as u8))
            });
            self.position += 1;
            if self.candidates.is_empty() {
                self.reset();
            }
        }
        if self.position == 0 && starts_keyword(key) {
            self.candidates = snippets
                .iter()
                .enumerate()
                .filter_map(|(index, snippet)| {
                    (snippet.keyword.as_bytes().first() == Some(&(key as u8))).then_some(index)
                })
                .collect();
            self.position = 1;
        }
        None
    }
}
#[derive(Clone, Copy, Default)]
struct Guards {
    enabled: bool,
    permissions: bool,
    direct_input: bool,
    secure: bool,
    excluded: bool,
    synthetic: bool,
    focus_matches: bool,
    contiguous: bool,
}
impl Guards {
    fn safe(self) -> bool {
        self.enabled
            && self.permissions
            && self.direct_input
            && !self.secure
            && !self.excluded
            && !self.synthetic
            && self.focus_matches
            && self.contiguous
    }
}
fn replacement_range(
    caret: isize,
    keyword: &str,
    delimiter: char,
    observed: &str,
) -> Option<(isize, isize)> {
    let expected = format!("{keyword}{delimiter}");
    let length = expected.encode_utf16().count() as isize;
    (observed == expected && caret >= length).then_some((caret - length, length))
}

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use accessibility_sys::*;
    use core_foundation::{base::TCFType, string::CFString};
    use core_foundation_sys::{
        base::{CFEqual, CFGetTypeID, CFRange, CFRelease, CFTypeRef},
        mach_port::{CFMachPortCreateRunLoopSource, CFMachPortInvalidate, CFMachPortRef},
        runloop::{
            kCFRunLoopDefaultMode, CFRunLoopAddSource, CFRunLoopGetCurrent, CFRunLoopRemoveSource,
            CFRunLoopRunInMode,
        },
        string::{CFStringGetTypeID, CFStringRef},
    };
    use objc2_app_kit::NSWorkspace;
    use std::{
        ffi::c_void,
        ptr,
        sync::mpsc::{sync_channel, Receiver, SyncSender},
        time::{Duration, Instant},
    };
    type Event = *mut c_void;
    type Callback = unsafe extern "C" fn(*mut c_void, u32, Event, *mut c_void) -> Event;
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn CGPreflightListenEventAccess() -> bool;
        fn CGRequestListenEventAccess() -> bool;
        fn CGEventTapCreate(
            tap: u32,
            place: u32,
            options: u32,
            mask: u64,
            callback: Callback,
            user: *mut c_void,
        ) -> CFMachPortRef;
        fn CGEventGetFlags(event: Event) -> u64;
        fn CGEventGetIntegerValueField(event: Event, field: u32) -> i64;
        fn CGEventKeyboardGetUnicodeString(
            event: Event,
            max: usize,
            length: *mut usize,
            text: *mut u16,
        );
    }
    #[link(name = "Carbon", kind = "framework")]
    extern "C" {
        fn IsSecureEventInputEnabled() -> bool;
        fn TISCopyCurrentKeyboardInputSource() -> CFTypeRef;
        fn TISGetInputSourceProperty(source: CFTypeRef, property: CFStringRef) -> CFTypeRef;
        static kTISPropertyInputSourceID: CFStringRef;
        static kTISPropertyInputSourceType: CFStringRef;
    }
    struct Owned(CFTypeRef);
    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CFRelease(self.0) };
            }
        }
    }
    fn owned(value: CFTypeRef) -> Option<Owned> {
        (!value.is_null()).then_some(Owned(value))
    }
    fn text(value: CFTypeRef) -> Option<String> {
        if value.is_null() || unsafe { CFGetTypeID(value) != CFStringGetTypeID() } {
            return None;
        }
        Some(unsafe { CFString::wrap_under_get_rule(value.cast()) }.to_string())
    }
    fn attribute(element: AXUIElementRef, name: &str) -> Option<Owned> {
        let name = CFString::new(name);
        let mut value = ptr::null();
        let result = unsafe {
            AXUIElementCopyAttributeValue(element, name.as_concrete_TypeRef(), &mut value)
        };
        let value = owned(value)?;
        (result == 0).then_some(value)
    }
    fn settable(element: AXUIElementRef, name: &str) -> bool {
        let name = CFString::new(name);
        let mut result = 0;
        unsafe {
            AXUIElementIsAttributeSettable(element, name.as_concrete_TypeRef(), &mut result) == 0
                && result != 0
        }
    }
    fn set(element: AXUIElementRef, name: &str, value: CFTypeRef) -> bool {
        let name = CFString::new(name);
        unsafe { AXUIElementSetAttributeValue(element, name.as_concrete_TypeRef(), value) == 0 }
    }
    pub fn permissions() -> (bool, bool) {
        unsafe { (AXIsProcessTrusted(), CGPreflightListenEventAccess()) }
    }
    pub fn request_input_monitoring() {
        unsafe {
            CGRequestListenEventAccess();
        }
    }
    fn direct_input() -> bool {
        let Some(source) = owned(unsafe { TISCopyCurrentKeyboardInputSource() }) else {
            return false;
        };
        let kind =
            text(unsafe { TISGetInputSourceProperty(source.0, kTISPropertyInputSourceType) });
        let id = text(unsafe { TISGetInputSourceProperty(source.0, kTISPropertyInputSourceID) });
        kind.as_deref() == Some("TISTypeKeyboardLayout")
            && matches!(
                id.as_deref(),
                Some("com.apple.keylayout.US" | "com.apple.keylayout.ABC")
            )
    }
    struct Key {
        key: Option<char>,
        serial: u64,
        generation: u64,
        at: Instant,
    }
    struct TapContext {
        sender: SyncSender<Key>,
        serial: Arc<AtomicU64>,
        shared: Arc<Shared>,
        interrupted: Arc<AtomicBool>,
    }
    // No AX, AppKit, locks, waiting, logging, text buffers or unbounded work in this callback.
    unsafe extern "C" fn callback(
        _: *mut c_void,
        kind: u32,
        event: Event,
        user: *mut c_void,
    ) -> Event {
        let context = &*(user as *const TapContext);
        if kind == u32::MAX || kind == u32::MAX - 1 {
            context.interrupted.store(true, Ordering::SeqCst);
        }
        // Shift/caps-lock transitions do not change focus or start composition under
        // the explicitly allowed direct keyboard layouts. Keep uppercase keywords usable.
        if kind == 12
            && !event.is_null()
            && CGEventGetFlags(event) & ((1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)) == 0
        {
            return event;
        }
        let serial = context.serial.fetch_add(1, Ordering::SeqCst) + 1;
        let mut key = None;
        if kind == 10 && !event.is_null() && CGEventGetFlags(event) & ((1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)) == 0
            && CGEventGetIntegerValueField(event, 8) == 0 // autorepeat
            && CGEventGetIntegerValueField(event, 41) == 0
        // reject all process-created events
        {
            let mut unit = 0u16;
            let mut length = 0;
            CGEventKeyboardGetUnicodeString(event, 1, &mut length, &mut unit);
            if length == 1 && unit < 128 {
                let ch = unit as u8 as char;
                if ch.is_ascii_graphic() || matches!(ch, ' ' | '\t' | '\n' | '\r') {
                    key = Some(if ch == '\r' { '\n' } else { ch });
                }
            }
        }
        // Capacity one; a slow AX target drops the candidate instead of delaying typing.
        let _ = context.sender.try_send(Key {
            key,
            serial,
            generation: context.shared.generation.load(Ordering::SeqCst),
            at: Instant::now(),
        });
        event
    }
    pub fn run(shared: Arc<Shared>) {
        let (sender, receiver) = sync_channel(1);
        let serial = Arc::new(AtomicU64::new(0));
        let interrupted = Arc::new(AtomicBool::new(false));
        let mut context = Box::new(TapContext {
            sender,
            serial: serial.clone(),
            shared: shared.clone(),
            interrupted: interrupted.clone(),
        });
        // Listen-only at the session tail: original delimiters always reach the destination.
        let tap = unsafe {
            CGEventTapCreate(
                1,
                1,
                1,
                (1 << 10) | (1 << 12) | (1 << 1) | (1 << 3) | (1 << 25) | (1 << 22),
                callback,
                (&mut *context as *mut TapContext).cast(),
            )
        };
        let Some(tap_guard) = owned(tap.cast()) else {
            *shared.error.lock().unwrap_or_else(|e| e.into_inner()) =
                Some("Input monitoring could not start. Review permissions and retry.".into());
            // Avoid repeated tap creation attempts while enabled after a platform refusal.
            shared.tap_failed.store(true, Ordering::Release);
            return;
        };
        let source = unsafe { CFMachPortCreateRunLoopSource(ptr::null(), tap, 0) };
        let Some(source_guard) = owned(source.cast()) else {
            unsafe { CFMachPortInvalidate(tap) };
            return;
        };
        let worker_shared = shared.clone();
        let worker_interrupted = interrupted.clone();
        let worker = std::thread::Builder::new()
            .name("prism-snippet-target".into())
            .spawn(move || process(receiver, serial, worker_shared, worker_interrupted));
        let Ok(worker) = worker else {
            unsafe { CFMachPortInvalidate(tap) };
            return;
        };
        unsafe { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode) };
        shared.active.store(true, Ordering::Release);
        while !shared.stop.load(Ordering::Acquire)
            && !interrupted.load(Ordering::Acquire)
            && shared
                .config
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .enabled
            && permissions() == (true, true)
        {
            unsafe {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 0);
            }
        }
        shared.active.store(false, Ordering::Release);
        shared.generation.fetch_add(1, Ordering::SeqCst);
        interrupted.store(true, Ordering::SeqCst);
        unsafe {
            CFMachPortInvalidate(tap);
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
        }
        drop(context); // invalidation precedes releasing the callback context
        let _ = worker.join();
        drop(source_guard);
        drop(tap_guard);
    }
    struct Snapshot {
        pid: i32,
        element: Owned,
        window: Owned,
        caret: isize,
    }
    impl Snapshot {
        fn same_target(&self, other: &Self) -> bool {
            self.pid == other.pid
                && unsafe {
                    CFEqual(self.element.0, other.element.0) != 0
                        && CFEqual(self.window.0, other.window.0) != 0
                }
        }
        fn element(&self) -> AXUIElementRef {
            self.element.0 as AXUIElementRef
        }
    }
    fn range(element: AXUIElementRef) -> Option<CFRange> {
        let value = attribute(element, "AXSelectedTextRange")?;
        if unsafe { CFGetTypeID(value.0) != AXValueGetTypeID() } {
            return None;
        }
        let mut range = CFRange {
            location: 0,
            length: 0,
        };
        (unsafe {
            AXValueGetValue(
                value.0 as AXValueRef,
                kAXValueTypeCFRange,
                (&mut range as *mut CFRange).cast(),
            )
        })
        .then_some(range)
    }
    fn range_value(location: isize, length: isize) -> Option<Owned> {
        let range = CFRange { location, length };
        owned(unsafe {
            AXValueCreate(kAXValueTypeCFRange, (&range as *const CFRange).cast()).cast()
        })
    }
    fn read_range(element: AXUIElementRef, location: isize, length: isize) -> Option<String> {
        if location < 0 || !(1..=65).contains(&length) {
            return None;
        }
        let range = range_value(location, length)?;
        let attribute = CFString::new("AXStringForRange");
        let mut result = ptr::null();
        let code = unsafe {
            AXUIElementCopyParameterizedAttributeValue(
                element,
                attribute.as_concrete_TypeRef(),
                range.0,
                &mut result,
            )
        };
        let result = owned(result)?;
        if code != 0 {
            return None;
        }
        let result = text(result.0)?;
        (result.encode_utf16().count() == length as usize).then_some(result)
    }
    fn snapshot(shared: &Shared) -> Option<Snapshot> {
        let config = shared.config.lock().ok()?.clone();
        let secure = unsafe { IsSecureEventInputEnabled() };
        if !(Guards {
            enabled: config.enabled && !shared.stop.load(Ordering::Acquire),
            permissions: permissions() == (true, true),
            direct_input: direct_input(),
            secure,
            focus_matches: true,
            contiguous: true,
            ..Default::default()
        })
        .safe()
        {
            return None;
        }
        let front = NSWorkspace::sharedWorkspace().frontmostApplication()?;
        let pid = front.processIdentifier();
        let bundle = front.bundleIdentifier()?.to_string();
        if pid <= 0
            || pid == std::process::id() as i32
            || config
                .excluded_apps
                .iter()
                .any(|excluded| excluded == &bundle)
            || [
                "com.apple.loginwindow",
                "com.apple.SecurityAgent",
                "com.agilebits.onepassword7",
                "com.1password.1password",
                "com.bitwarden.desktop",
                "com.apple.Passwords",
            ]
            .contains(&bundle.as_str())
        {
            return None;
        }
        let system = owned(unsafe { AXUIElementCreateSystemWide().cast() })?;
        unsafe {
            AXUIElementSetMessagingTimeout(system.0 as AXUIElementRef, 0.015);
        }
        let application = attribute(system.0 as AXUIElementRef, "AXFocusedApplication")?;
        let mut focused_pid = 0;
        if unsafe { AXUIElementGetPid(application.0 as AXUIElementRef, &mut focused_pid) } != 0
            || focused_pid != pid
        {
            return None;
        }
        let element = attribute(application.0 as AXUIElementRef, "AXFocusedUIElement")?;
        if unsafe { CFGetTypeID(element.0) != AXUIElementGetTypeID() } {
            return None;
        }
        let ax = element.0 as AXUIElementRef;
        unsafe {
            AXUIElementSetMessagingTimeout(ax, 0.015);
        }
        let role = text(attribute(ax, "AXRole")?.0)?;
        if !matches!(role.as_str(), "AXTextField" | "AXTextArea") {
            return None;
        }
        // A missing/unrecognized subrole is skipped; standard nonsecure text roles
        // may report AXUnknown. AXSecureTextField is never accepted.
        let subrole = text(attribute(ax, "AXSubrole")?.0)?;
        if !matches!(
            subrole.as_str(),
            "AXStandardTextField" | "AXUnknown" | "AXTextArea"
        ) {
            return None;
        }
        let window = attribute(application.0 as AXUIElementRef, "AXFocusedWindow")?;
        let element_window = attribute(ax, "AXWindow")?;
        if unsafe { CFEqual(window.0, element_window.0) == 0 } {
            return None;
        }
        let selection = range(ax)?;
        if selection.location < 0
            || selection.length != 0
            || !settable(ax, "AXSelectedTextRange")
            || !settable(ax, "AXSelectedText")
        {
            return None;
        }
        Some(Snapshot {
            pid,
            element,
            window,
            caret: selection.location,
        })
    }
    fn current(key: &Key, serial: &AtomicU64, shared: &Shared, interrupted: &AtomicBool) -> bool {
        !shared.stop.load(Ordering::Acquire)
            && !interrupted.load(Ordering::Acquire)
            && serial.load(Ordering::SeqCst) == key.serial
            && shared.generation.load(Ordering::SeqCst) == key.generation
            && key.at.elapsed() < Duration::from_millis(200)
    }
    fn process(
        receiver: Receiver<Key>,
        serial: Arc<AtomicU64>,
        shared: Arc<Shared>,
        interrupted: Arc<AtomicBool>,
    ) {
        let mut matcher = Matcher::default();
        let mut previous: Option<Snapshot> = None;
        let mut previous_serial = 0;
        let mut generation = 0;
        while !shared.stop.load(Ordering::Acquire) && !interrupted.load(Ordering::Acquire) {
            let Ok(key) = receiver.recv_timeout(Duration::from_millis(100)) else {
                continue;
            };
            objc2::rc::autoreleasepool(|_| {
                let reset = key.serial != previous_serial + 1 || generation != key.generation;
                previous_serial = key.serial;
                generation = key.generation;
                if reset {
                    matcher.reset();
                    previous = None;
                }
                let Some(ch) = key.key else {
                    matcher.reset();
                    previous = None;
                    return;
                };
                if !current(&key, &serial, &shared, &interrupted) {
                    matcher.reset();
                    previous = None;
                    return;
                }
                let snippets = shared
                    .registry
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clone();
                if snippets.is_empty() {
                    matcher.reset();
                    previous = None;
                    return;
                }
                if matcher.position == 0 && !starts_keyword(ch) {
                    previous = None;
                    return;
                }
                // The listen-only callback precedes delivery; give the native field time to apply it.
                std::thread::sleep(Duration::from_millis(8));
                let Some(target) = snapshot(&shared) else {
                    matcher.reset();
                    previous = None;
                    return;
                };
                let contiguous = previous.as_ref().is_some_and(|prior| {
                    prior.same_target(&target) && target.caret == prior.caret + 1
                });
                if (!contiguous && !starts_keyword(ch))
                    || read_range(target.element(), target.caret - 1, 1).as_deref()
                        != Some(ch.to_string().as_str())
                    || !current(&key, &serial, &shared, &interrupted)
                {
                    matcher.reset();
                    previous = None;
                    return;
                }
                if !contiguous {
                    matcher.reset();
                }
                if let Some(index) = matcher.feed(ch, &snippets, true) {
                    replace(
                        &target,
                        &snippets[index],
                        ch,
                        &key,
                        &serial,
                        &shared,
                        &interrupted,
                    );
                    previous = None;
                } else {
                    previous = Some(target);
                }
            });
        }
    }
    fn replace(
        target: &Snapshot,
        snippet: &Snippet,
        delimiter: char,
        key: &Key,
        serial: &AtomicU64,
        shared: &Shared,
        interrupted: &AtomicBool,
    ) {
        let length = snippet.keyword.len() as isize + 1;
        let Some(observed) = read_range(target.element(), target.caret - length, length) else {
            return;
        };
        let Some((start, length)) =
            replacement_range(target.caret, &snippet.keyword, delimiter, &observed)
        else {
            return;
        };
        let Some(latest) = snapshot(shared) else {
            return;
        };
        if !latest.same_target(target)
            || latest.caret != target.caret
            || !current(key, serial, shared, interrupted)
        {
            return;
        }
        let Some(selection) = range_value(start, length) else {
            return;
        };
        if !set(target.element(), "AXSelectedTextRange", selection.0) {
            return;
        }
        // Validate the exact selected text after changing selection; never send backspaces or Cmd+V.
        let selected =
            attribute(target.element(), "AXSelectedText").and_then(|value| text(value.0));
        let actual_range = range(target.element());
        let valid_selection =
            actual_range.is_some_and(|r| r.location == start && r.length == length);
        // snapshot() deliberately rejects non-collapsed selection, so verify foreground identity directly here.
        let front_matches = NSWorkspace::sharedWorkspace()
            .frontmostApplication()
            .is_some_and(|front| front.processIdentifier() == target.pid);
        let focus_matches = owned(unsafe { AXUIElementCreateApplication(target.pid).cast() })
            .is_some_and(|app| {
                attribute(app.0 as AXUIElementRef, "AXFocusedUIElement")
                    .is_some_and(|element| unsafe { CFEqual(element.0, target.element.0) != 0 })
                    && attribute(app.0 as AXUIElementRef, "AXFocusedWindow")
                        .is_some_and(|window| unsafe { CFEqual(window.0, target.window.0) != 0 })
            });
        if !valid_selection
            || selected.as_deref() != Some(observed.as_str())
            || !front_matches
            || !focus_matches
            || permissions() != (true, true)
            || unsafe { IsSecureEventInputEnabled() }
            || !direct_input()
            || !current(key, serial, shared, interrupted)
        {
            // Restore only an untouched selection in the same foreground target.
            if valid_selection
                && front_matches
                && focus_matches
                && current(key, serial, shared, interrupted)
            {
                if let Some(caret) = range_value(target.caret, 0) {
                    set(target.element(), "AXSelectedTextRange", caret.0);
                }
            }
            return;
        }
        let replacement = CFString::new(&format!("{}{delimiter}", snippet.text));
        if !set(
            target.element(),
            "AXSelectedText",
            replacement.as_CFTypeRef(),
        ) {
            if current(key, serial, shared, interrupted) {
                if let Some(caret) = range_value(target.caret, 0) {
                    set(target.element(), "AXSelectedTextRange", caret.0);
                }
            }
        }
        // No synthetic keyboard events are generated, and the matcher is reset by the caller.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unverified_automatic_expansion_cannot_be_enabled() {
        assert!(validate_activation(true).is_err());
        assert!(validate_activation(false).is_ok());
    }
    fn snippets() -> Vec<Snippet> {
        vec![
            Snippet {
                keyword: ";email".into(),
                text: "안녕 👋\ne@example.com".into(),
            },
            Snippet {
                keyword: ";e".into(),
                text: "short".into(),
            },
        ]
    }
    fn matched(input: &str) -> Option<usize> {
        let mut matcher = Matcher::default();
        input
            .chars()
            .filter_map(|ch| matcher.feed(ch, &snippets(), true))
            .last()
    }
    #[test]
    fn exact_keyword_and_delimiters() {
        for delimiter in [' ', '\t', '\n'] {
            assert_eq!(matched(&format!(";email{delimiter}")), Some(0));
        }
        assert_eq!(matched(";e "), Some(1));
        assert_eq!(matched(";emails "), None);
        assert_eq!(matched(";EMAIL "), None);
        assert_eq!(matched(";email"), None);
    }
    #[test]
    fn supports_all_canonical_prefixes_and_internal_punctuation() {
        for keyword in [";Email", "!email", "/email", ":email", ";a:!/;x"] {
            let items = vec![Snippet {
                keyword: keyword.into(),
                text: "value".into(),
            }];
            let mut matcher = Matcher::default();
            for key in keyword.chars() {
                assert_eq!(matcher.feed(key, &items, true), None);
            }
            assert_eq!(matcher.feed(' ', &items, true), Some(0));
        }
    }
    #[test]
    fn unicode_and_composition_reset_candidate() {
        assert_eq!(matched(";ema한il "), None);
        assert_eq!(matched(";ema\u{301}il "), None);
        assert_eq!(matched(";ema👋il "), None);
        let mut matcher = Matcher::default();
        for ch in ";email".chars() {
            matcher.feed(ch, &snippets(), true);
        }
        assert_eq!(matcher.feed(' ', &snippets(), false), None);
        assert_eq!(matcher.feed(' ', &snippets(), true), None);
    }
    #[test]
    fn all_context_guards_fail_closed() {
        let safe = Guards {
            enabled: true,
            permissions: true,
            direct_input: true,
            secure: false,
            excluded: false,
            synthetic: false,
            focus_matches: true,
            contiguous: true,
        };
        assert!(safe.safe());
        for unsafe_context in [
            Guards {
                enabled: false,
                ..safe
            },
            Guards {
                permissions: false,
                ..safe
            },
            Guards {
                direct_input: false,
                ..safe
            },
            Guards {
                secure: true,
                ..safe
            },
            Guards {
                excluded: true,
                ..safe
            },
            Guards {
                synthetic: true,
                ..safe
            },
            Guards {
                focus_matches: false,
                ..safe
            },
            Guards {
                contiguous: false,
                ..safe
            },
        ] {
            assert!(!unsafe_context.safe());
        }
    }
    #[test]
    fn exact_utf16_range_preserves_unicode_prefix_and_delimiter() {
        let prefix = "한글 👋 ";
        let caret = (prefix.encode_utf16().count() + 7) as isize;
        assert_eq!(
            replacement_range(caret, ";email", ' ', ";email "),
            Some((prefix.encode_utf16().count() as isize, 7))
        );
        assert_eq!(replacement_range(caret, ";email", ' ', ";EMAIL "), None);
        assert_eq!(replacement_range(2, ";email", ' ', ";email "), None);
        assert_eq!(snippets()[0].text, "안녕 👋\ne@example.com");
    }
    #[test]
    fn invalid_and_unbounded_keywords_rejected() {
        for keyword in ["", ";", "email", ";한글", ";a b", ";a\n", ";a👋"] {
            assert!(!valid_keyword(keyword));
        }
        assert!(valid_keyword(";Email_2-x"));
        assert!(valid_keyword(&format!(";{}", "a".repeat(47))));
        assert!(!valid_keyword(&format!(";{}", "a".repeat(48))));
    }
    #[test]
    fn focus_paste_or_registry_reset_prevents_suffix_expansion() {
        let mut matcher = Matcher::default();
        for ch in ";ema".chars() {
            matcher.feed(ch, &snippets(), true);
        }
        matcher.reset();
        for ch in "il ".chars() {
            assert_eq!(matcher.feed(ch, &snippets(), true), None);
        }
    }
    #[test]
    fn registry_rejects_duplicates_templates_and_non_snippets() {
        let entry = |id: &str, keyword: &str, value: &str, kind: &str| crate::library::Entry {
            id: id.into(),
            title: id.into(),
            kind: kind.into(),
            value: value.into(),
            keyword: Some(keyword.into()),
        };
        let result = registry(vec![
            entry("1", ";a", "a", "snippet"),
            entry("2", ";a", "b", "snippet"),
            entry("3", ";date", "{date}", "snippet"),
            entry("4", ";url", "https://example.com", "link"),
            entry("5", ";ok", "한국 👋", "snippet"),
        ]);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].keyword, ";ok");
    }
}
