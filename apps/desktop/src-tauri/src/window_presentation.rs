use std::{collections::HashMap, sync::Mutex};
use tauri::{Manager, WebviewWindow};

#[derive(Default)]
struct Presentation {
    ready: bool,
    pending_show: bool,
}

impl Presentation {
    fn request_show(&mut self) -> bool {
        self.pending_show = !self.ready;
        self.ready
    }

    fn begin_load(&mut self, visible: bool) {
        self.ready = false;
        self.pending_show |= visible;
    }

    fn finish_render(&mut self) -> bool {
        self.ready = true;
        std::mem::take(&mut self.pending_show)
    }
}

#[derive(Default)]
pub struct WindowPresentation(Mutex<HashMap<String, Presentation>>);

pub fn request_show(window: &WebviewWindow) -> bool {
    window
        .state::<WindowPresentation>()
        .0
        .lock()
        .unwrap()
        .entry(window.label().into())
        .or_default()
        .request_show()
}

pub fn begin_load(window: &WebviewWindow) {
    let visible = window.is_visible().unwrap_or(false);
    window
        .state::<WindowPresentation>()
        .0
        .lock()
        .unwrap()
        .entry(window.label().into())
        .or_default()
        .begin_load(visible);
    if visible {
        let _ = window.hide();
    }
}

pub fn forget(window: &tauri::Window) {
    window
        .state::<WindowPresentation>()
        .0
        .lock()
        .unwrap()
        .remove(window.label());
}

#[tauri::command]
pub async fn prepare_window_appearance(
    window: WebviewWindow,
    dark: bool,
    blur: u8,
    opacity: Option<u8>,
) -> Result<bool, String> {
    window
        .set_theme(Some(if dark {
            tauri::Theme::Dark
        } else {
            tauri::Theme::Light
        }))
        .map_err(|error| error.to_string())?;
    window
        .set_background_color(Some(tauri::window::Color(0, 0, 0, 0)))
        .map_err(|error| error.to_string())?;
    super::set_window_blur(window.clone(), blur).await?;
    #[cfg(target_os = "macos")]
    {
        super::window_glass::apply_tint(&window, dark, opacity.unwrap_or(64)).await?;
        Ok(true)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = opacity;
        Ok(false)
    }
}

#[tauri::command]
pub fn window_render_ready(window: WebviewWindow) -> Result<(), String> {
    let show = window
        .state::<WindowPresentation>()
        .0
        .lock()
        .unwrap()
        .entry(window.label().into())
        .or_default()
        .finish_render();
    if show {
        if window.label() == "main" {
            super::show_palette(window.app_handle());
        } else {
            window.show().map_err(|error| error.to_string())?;
            window.set_focus().map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::Presentation;

    #[test]
    fn cold_open_waits_for_render_and_only_shows_once() {
        let mut state = Presentation::default();
        assert!(!state.request_show());
        assert!(!state.request_show());
        state.begin_load(false);
        assert!(state.finish_render());
        assert!(!state.finish_render());
        assert!(state.request_show());
    }

    #[test]
    fn background_render_does_not_open_the_palette() {
        let mut state = Presentation::default();
        state.begin_load(false);
        assert!(!state.finish_render());
        assert!(state.request_show());
    }

    #[test]
    fn reload_restores_only_a_visible_or_requested_window() {
        let mut state = Presentation::default();
        state.finish_render();
        state.begin_load(true);
        assert!(state.finish_render());
        state.begin_load(false);
        assert!(!state.finish_render());
    }
}
