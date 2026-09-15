use std::sync::Mutex;
use tauri::{Manager, WebviewWindow};

#[derive(Default)]
pub struct ClipboardPresentation(Mutex<Pending>);

#[derive(Default)]
struct Pending {
    sequence: u64,
    request: Option<u64>,
}
impl Pending {
    fn begin(&mut self) -> u64 {
        self.sequence = self.sequence.wrapping_add(1);
        self.request = Some(self.sequence);
        self.sequence
    }
    fn complete(&mut self, id: u64) -> bool {
        if self.request != Some(id) {
            return false;
        }
        self.request = None;
        true
    }
}
pub fn begin(app: &tauri::AppHandle) -> u64 {
    app.state::<ClipboardPresentation>()
        .0
        .lock()
        .unwrap()
        .begin()
}
pub fn cancel(app: &tauri::AppHandle) {
    app.state::<ClipboardPresentation>()
        .0
        .lock()
        .unwrap()
        .request = None;
}

#[tauri::command]
pub fn pending_clipboard_presentation(window: WebviewWindow) -> Option<u64> {
    if window.label() != "main" {
        return None;
    }
    window
        .state::<ClipboardPresentation>()
        .0
        .lock()
        .unwrap()
        .request
}

/// Called after the clipboard React tree is committed, never from the generic root render.
#[tauri::command]
pub fn complete_clipboard_presentation(window: WebviewWindow, request_id: u64) -> bool {
    if window.label() != "main" {
        return false;
    }
    let ready = window
        .state::<ClipboardPresentation>()
        .0
        .lock()
        .unwrap()
        .complete(request_id);
    if ready {
        super::show_palette_impl(window.app_handle(), false);
    }
    ready
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_latest_prepared_view_can_reveal_once() {
        let mut pending = Pending::default();
        let first = pending.begin();
        let second = pending.begin();
        assert!(!pending.complete(first));
        assert!(pending.complete(second));
        assert!(!pending.complete(second));
        let cancelled = pending.begin();
        pending.request = None;
        assert!(!pending.complete(cancelled));
    }
}
