mod updates;
#[cfg(target_os = "macos")]
mod update_signature;
mod ai;
mod ai_history;
mod ai_usage;
mod ai_key_session;
#[cfg(target_os = "macos")]
mod keychain;
mod ai_preferences;
mod ai_stream;
mod ai_tools;
mod ai_window;
mod app_catalog;
mod app_icon;
mod application_index;
mod application_watcher;
mod arithmetic;
mod clipboard_history;
mod currency;
mod library;
mod permissions;
mod paste;
mod dictation;
mod script_commands;
#[cfg(desktop)]
mod shortcut;
mod snippet_expansion;
mod system_commands;
mod system_power;
mod web;
mod window_management;
mod window_preferences;
mod migration_journal;
mod window_presentation;
#[cfg(target_os = "macos")]
mod window_glass;

use application_index::{ApplicationIndex, ApplicationSearchResult};
use serde::Serialize;
#[cfg(target_os = "windows")]
use tauri::window::{Effect, EffectState, EffectsBuilder};
#[cfg(not(target_os = "macos"))]
use tauri::PhysicalPosition;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};

fn validate_plain_text(text: &str) -> Result<(), String> {
    if text.is_empty() || text.len() > 128 * 1024 || text.contains('\0') {
        return Err("복사할 텍스트를 확인하세요. 최대 128 KB까지 사용할 수 있습니다.".into());
    }
    Ok(())
}

#[tauri::command]
fn copy_plain_text(text: String) -> Result<(), String> {
    validate_plain_text(&text)?;
    arboard::Clipboard::new()
        .map_err(|_| "클립보드에 접근하지 못했습니다.")?
        .set_text(text)
        .map_err(|_| "클립보드에 복사하지 못했습니다.".into())
}

#[tauri::command]
async fn paste_plain_text(app: AppHandle, text: String) -> Result<(), String> {
    validate_plain_text(&text)?;
    paste::paste_text(app, text).await
}

fn show_palette(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    if !window_presentation::request_show(&window) {
        return;
    }
    window_management::remember_frontmost_app(app);
    // Chat keeps its existing frame across hide/show, including during a resize transition.
    if !app
        .state::<ai_window::AiWorkspace>()
        .0
        .load(std::sync::atomic::Ordering::Relaxed)
    {
        let _ = position_palette(app, &window);
    }
    let _ = window.show();
    let _ = window.set_focus();
}

#[cfg(not(target_os = "macos"))]
fn position_palette(app: &AppHandle, window: &tauri::WebviewWindow) -> Result<(), String> {
    let monitor = app
        .cursor_position()
        .ok()
        .and_then(|cursor| app.monitor_from_point(cursor.x, cursor.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten())
        .ok_or_else(|| "Prism could not identify the current monitor.".to_string())?;
    let window_size = window.outer_size().map_err(|error| error.to_string())?;
    let work_area = monitor.work_area();
    let (x, y) = palette_position(
        work_area.position.x,
        work_area.position.y,
        work_area.size.width,
        work_area.size.height,
        window_size.width,
        window_size.height,
    );
    window
        .set_position(PhysicalPosition::new(x, y))
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "macos")]
fn position_palette(_app: &AppHandle, window: &tauri::WebviewWindow) -> Result<(), String> {
    use objc2_app_kit::{NSEvent, NSScreen, NSWindow};
    use objc2_foundation::{MainThreadMarker, NSPoint, NSRect};

    fn contains(rect: NSRect, point: NSPoint) -> bool {
        point.x >= rect.origin.x
            && point.x < rect.origin.x + rect.size.width
            && point.y >= rect.origin.y
            && point.y < rect.origin.y + rect.size.height
    }

    let mtm = MainThreadMarker::new().ok_or_else(|| {
        "Prism can only position its palette from the macOS main thread.".to_string()
    })?;
    let cursor = NSEvent::mouseLocation();
    let screens = NSScreen::screens(mtm);
    let visible_frame = screens
        .iter()
        .find(|screen| contains(screen.frame(), cursor))
        .map(|screen| screen.visibleFrame())
        .or_else(|| NSScreen::mainScreen(mtm).map(|screen| screen.visibleFrame()))
        .ok_or_else(|| "Prism could not identify the current monitor.".to_string())?;
    let native_window = window.ns_window().map_err(|error| error.to_string())?;
    if native_window.is_null() {
        return Err("Prism could not access its native palette window.".to_string());
    }
    let native_window = unsafe { &*native_window.cast::<NSWindow>() };
    let window_frame = native_window.frame();
    let origin = palette_position_appkit(
        visible_frame.origin.x,
        visible_frame.origin.y,
        visible_frame.size.width,
        visible_frame.size.height,
        window_frame.size.width,
        window_frame.size.height,
    );
    native_window.setFrameOrigin(NSPoint::new(origin.0, origin.1));
    Ok(())
}

#[cfg(any(not(target_os = "macos"), test))]
fn palette_position(
    work_x: i32,
    work_y: i32,
    work_width: u32,
    work_height: u32,
    window_width: u32,
    window_height: u32,
) -> (i32, i32) {
    let x = i64::from(work_x)
        + (i64::from(work_width)
            .saturating_sub(i64::from(window_width))
            .max(0)
            / 2);
    let center_y = i64::from(work_y) + i64::from(work_height) / 3;
    let y = (center_y - i64::from(window_height) / 2).max(i64::from(work_y));
    (
        x.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32,
        y.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32,
    )
}

#[cfg(target_os = "macos")]
fn palette_position_appkit(
    work_x: f64,
    work_y: f64,
    work_width: f64,
    work_height: f64,
    window_width: f64,
    window_height: f64,
) -> (f64, f64) {
    let x = work_x + ((work_width - window_width) / 2.0).max(0.0);
    let maximum_y = work_y + (work_height - window_height).max(0.0);
    let center_y = work_y + work_height * (2.0 / 3.0);
    let y = (center_y - window_height / 2.0).clamp(work_y, maximum_y);
    (x.round(), y.round())
}

#[cfg(desktop)]
fn toggle_palette(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };

    if window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false) {
        let _ = window.hide();
    } else {
        show_palette(app);
    }
}

#[cfg(desktop)]
fn dispatch_command_hotkey(app: &AppHandle, command_id: &str) {
    if command_id == "prism:dictation-prompt" {
        let _ = dictation::dictation_prompt_toggle(app.clone());
        return;
    }
    if command_id == "prism:dictation" {
        let _ = dictation::dictation_toggle(app.clone());
        return;
    }
    show_palette(app);
    let _ = app.emit(
        "prism:command-hotkey",
        CommandHotkeyPayload {
            command_id: command_id.to_string(),
        },
    );
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CommandHotkeyPayload {
    command_id: String,
}

#[tauri::command]
fn open_settings_window(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("settings") {
        if !window_presentation::request_show(&window) {
            return Ok(());
        }
        window
            .set_decorations(true)
            .map_err(|error| error.to_string())?;
        window
            .set_resizable(true)
            .map_err(|error| error.to_string())?;
        window.show().map_err(|error| error.to_string())?;
        return window.set_focus().map_err(|error| error.to_string());
    }

    let window = WebviewWindowBuilder::new(
        &app,
        "settings",
        WebviewUrl::App("index.html?window=settings".into()),
    )
    .title("Prism Settings")
    .inner_size(920.0, 680.0)
    .min_inner_size(720.0, 520.0)
    .decorations(true)
    .resizable(true)
    .center()
    .visible(false)
    .transparent(true)
    .background_color(tauri::window::Color(0, 0, 0, 0))
    .build()
    .map_err(|error| format!("Prism could not open Settings: {error}"))?;
    if window_presentation::request_show(&window) {
        window.show().map_err(|error| error.to_string())?;
        window.set_focus().map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn search_applications(
    query: String,
    limit: Option<usize>,
    index: State<'_, ApplicationIndex>,
) -> Vec<ApplicationSearchResult> {
    index.search(&query, limit.unwrap_or(40))
}

#[tauri::command]
fn get_application(
    application_id: String,
    index: State<'_, ApplicationIndex>,
) -> Option<ApplicationSearchResult> {
    index.lookup(&application_id)
}

#[tauri::command]
async fn refresh_application_index(
    app: AppHandle,
    index: State<'_, ApplicationIndex>,
) -> Result<usize, String> {
    let index = index.inner().clone();
    let application_count = tauri::async_runtime::spawn_blocking(move || index.refresh())
        .await
        .map_err(|error| format!("The application index refresh did not finish: {error}"))??;
    application_watcher::emit_update(&app, application_count);
    Ok(application_count)
}

#[tauri::command]
async fn load_application_icon(
    app: AppHandle,
    cache: State<'_, app_icon::ApplicationIconCache>,
    target: String,
) -> Result<Option<String>, String> {
    let cache_root = app
        .path()
        .app_cache_dir()
        .map_err(|error| error.to_string())?;
    app_icon::load_application(cache.inner().clone(), cache_root, target).await
}

#[tauri::command]
async fn get_currency_rates(
    app: AppHandle,
    rates: State<'_, currency::CurrencyRates>,
) -> Result<currency::RateSnapshot, String> {
    rates
        .load(
            app.path()
                .app_cache_dir()
                .map_err(|error| error.to_string())?,
        )
        .await
}

#[tauri::command]
async fn load_system_icon(
    app: AppHandle,
    cache: State<'_, app_icon::ApplicationIconCache>,
    command_id: String,
) -> Result<Option<String>, String> {
    let cache_root = app
        .path()
        .app_cache_dir()
        .map_err(|error| error.to_string())?;
    app_icon::load_system(cache.inner().clone(), cache_root, command_id).await
}

#[tauri::command]
async fn clear_application_icon_cache(
    app: AppHandle,
    cache: State<'_, app_icon::ApplicationIconCache>,
) -> Result<(), String> {
    let cache_root = app
        .path()
        .app_cache_dir()
        .map_err(|error| error.to_string())?;
    app_icon::clear(cache.inner().clone(), cache_root).await?;
    app.emit("prism:application-icon-cache-cleared", ())
        .map_err(|error| {
            format!("Prism cleared the icon cache but could not notify its windows: {error}")
        })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeActionResult {
    usage_recorded: bool,
}

#[tauri::command]
fn launch_application(
    application_id: String,
    target: String,
    index: State<'_, ApplicationIndex>,
) -> Result<NativeActionResult, String> {
    if !index.contains(&application_id, &target) {
        return Err("Prism refused to open an application outside its current index.".to_string());
    }
    app_catalog::launch(&target)?;
    Ok(NativeActionResult {
        usage_recorded: index.record_launch(&application_id).is_ok(),
    })
}

#[tauri::command]
fn reveal_application(
    application_id: String,
    target: String,
    index: State<'_, ApplicationIndex>,
) -> Result<NativeActionResult, String> {
    if !index.contains(&application_id, &target) {
        return Err(
            "Prism refused to reveal an application outside its current index.".to_string(),
        );
    }
    app_catalog::reveal(&target)?;
    Ok(NativeActionResult {
        usage_recorded: false,
    })
}

#[tauri::command]
async fn get_glass_lighting(window: tauri::WebviewWindow) -> Result<Option<[f64; 2]>, String> {
    #[cfg(target_os = "macos")]
    return window_glass::lighting(window).await;
    #[cfg(not(target_os = "macos"))]
    { let _ = window; Ok(None) }
}

#[tauri::command]
async fn set_window_blur(window: tauri::WebviewWindow, strength: u8) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    return window_glass::apply(&window, strength).await;

    #[cfg(not(target_os = "macos"))]
    if strength == 0 {
        return window.set_effects(None).map_err(|error| error.to_string());
    }

    #[cfg(target_os = "windows")]
    let effect = Effect::Acrylic;

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    return Ok(());

    #[cfg(target_os = "windows")]
    window
        .set_effects(
            EffectsBuilder::new()
                .effect(effect)
                .state(EffectState::Active)
                .radius(26.0)
                .build(),
        )
        .map_err(|error| error.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show_palette(app)))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(updates::Updates::default())
        .manage(window_presentation::WindowPresentation::default())
        .manage(app_icon::ApplicationIconCache::default())
        .manage(currency::CurrencyRates::default())
        .manage(library::Library::default())
        .manage(library::backup::BackupState::default())
        .manage(ai::AiRequests::default())
        .manage(ai_tools::AiTools::default())
        .manage(ai_history::AiHistory::default())
        .manage(ai_window::AiWorkspace::default())
        .manage(ai_preferences::AiPreferences::default())
        .manage(script_commands::ScriptCommandRegistry::default())
        .manage(window_management::WindowManager::default())
        .manage(window_preferences::WindowPreferences::default())
        .manage(migration_journal::MigrationJournal::default())
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Focused(true)) {
                let app = window.app_handle().clone();
                tauri::async_runtime::spawn_blocking(move || { permissions::refresh(&app); });
            }
            #[cfg(target_os = "macos")]
            if matches!(
                event,
                tauri::WindowEvent::Resized(_)
                    | tauri::WindowEvent::Focused(true)
                    | tauri::WindowEvent::ThemeChanged(_)
                    | tauri::WindowEvent::ScaleFactorChanged { .. }
            ) {
                if let Some(webview) = window.app_handle().get_webview_window(window.label()) {
                    window_glass::schedule_refresh(&webview);
                }
            }
            if matches!(event, tauri::WindowEvent::Destroyed) {
                window_presentation::forget(window);
            }
            #[cfg(desktop)]
            let has_recovery_shortcut = window
                .app_handle()
                .try_state::<shortcut::GlobalShortcutManager>()
                .map(|manager| manager.is_registered())
                .unwrap_or(false);

            #[cfg(not(desktop))]
            let has_recovery_shortcut = true;

            if window.label() == "main"
                && matches!(event, tauri::WindowEvent::Focused(false))
                && window.is_visible().unwrap_or(false)
                && has_recovery_shortcut
                && !window
                    .app_handle()
                    .state::<ai_window::AiWorkspace>()
                    .0
                    .load(std::sync::atomic::Ordering::Relaxed)
            {
                let _ = window.hide();
            }
        })
        .on_page_load(|webview, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Started) {
                if let Some(window) = webview.app_handle().get_webview_window(webview.label()) {
                    window_presentation::begin_load(&window);
                }
            }
        })
        .setup(|app| {
            updates::start(app.handle().clone());
            dictation::install(app.handle());
            #[cfg(target_os = "macos")]
            app.handle()
                .set_activation_policy(tauri::ActivationPolicy::Accessory)?;

            let database_path = app
                .path()
                .app_data_dir()?
                .join("application-index-v1.sqlite3");
            let application_index =
                ApplicationIndex::open(&database_path).map_err(std::io::Error::other)?;
            app.manage(application_index.clone());

            let clipboard_history = clipboard_history::ClipboardHistory::default();
            if let Err(error) = clipboard_history.initialize(
                app.path()
                    .app_data_dir()?
                    .join("clipboard-history-v1.sqlite3"),
            ) {
                eprintln!("Clipboard history could not be opened: {error}");
            }
            clipboard_history.start_monitor()?;
            app.manage(clipboard_history);

            if let Err(error) = app
                .state::<script_commands::ScriptCommandRegistry>()
                .initialize(app.path().app_data_dir()?.join("script-runs-v1.json"))
            {
                eprintln!("Script run history could not be opened: {error}");
            }
            snippet_expansion::setup(app.handle());

            match application_watcher::start(app.handle().clone(), application_index.clone()) {
                Ok(watcher) => {
                    app.manage(watcher);
                }
                Err(error) => eprintln!("Prism could not monitor installed applications: {error}"),
            }

            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn_blocking(move || match application_index.refresh() {
                Ok(application_count) => {
                    application_watcher::emit_update(&app_handle, application_count)
                }
                Err(error) => {
                    eprintln!("Prism could not refresh its application index at startup: {error}")
                }
            });

            #[cfg(desktop)]
            shortcut::install(app, toggle_palette, dispatch_command_hotkey)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            updates::get_update_status,
            updates::check_for_updates,
            updates::install_update,
            updates::restart_after_update,
            permissions::get_permission_runtime,
            permissions::reveal_permission_target,
            permissions::refresh_accessibility_permission,
            shortcut::modifier::set_shortcut_capture,
            dictation::catalog::dictation_list_models,
            ai_usage::ai_usage_summary,
            dictation::dictation_get_settings,
            dictation::dictation_save_settings,
            dictation::dictation_key_status,
            dictation::dictation_key_info,
            dictation::dictation_unlock_key,
            dictation::dictation_save_key,
            dictation::dictation_delete_key,
            dictation::dictation_toggle,
            dictation::dictation_prompt_toggle,
            dictation::dictation_action,
            dictation::dictation_pick_file,
            copy_plain_text,
            paste_plain_text,
            snippet_expansion::snippet_expansion_status,
            snippet_expansion::snippet_expansion_configure,
            snippet_expansion::snippet_expansion_request_permissions,
            script_commands::list_script_command_runs,
            window_presentation::prepare_window_appearance,
            window_presentation::window_render_ready,
            library::library_load,
            library::backup::backup_export,
            library::backup::backup_preview_import,
            library::backup::backup_apply_import,
            library::library_save_entry,
            library::library_delete_entry,
            library::library_set_favorite,
            library::library_reorder_favorites,
            library::library_choose_path,
            library::library_add_root,
            library::library_remove_root,
            library::library_refresh_files,
            library::library_search_files,
            library::library_file_action,
            library::library_entry_action,
            library::library_preview_file,
            library::library_prepare_entry,
            library::library_run_entry,
            clipboard_history::delete_clipboard_history_entry,
            clipboard_history::paste_clipboard_history_entry,
            ai::ai_list_models,
            ai::ai_key_status,
            ai::ai_key_info,
            ai::ai_unlock_key,
            ai_preferences::ai_get_selection,
            ai_preferences::ai_set_selection,
            ai::ai_save_key,
            ai::ai_delete_key,
            ai::ai_chat,
            ai_tools::ai_get_tools,
            ai_tools::ai_set_tools,
            ai_tools::ai_add_folder,
            ai_tools::ai_remove_folder,
            ai_history::ai_load_history,
            ai_history::ai_save_session,
            ai_history::ai_delete_session,
            ai_history::ai_export_session,
            ai_window::set_ai_workspace,
            ai::ai_cancel,
            open_settings_window,
            search_applications,
            get_application,
            refresh_application_index,
            load_application_icon,
            load_system_icon,
            get_currency_rates,
            clear_application_icon_cache,
            launch_application,
            reveal_application,
            set_window_blur,
            get_glass_lighting,
            clipboard_history::get_clipboard_history_settings,
            clipboard_history::set_clipboard_history_retention,
            clipboard_history::set_clipboard_history_entry_pinned,
            clipboard_history::get_clipboard_history_entry_text,
            clipboard_history::get_clipboard_history_entry_preview,
            clipboard_history::get_clipboard_history_enabled,
            clipboard_history::set_clipboard_history_enabled,
            clipboard_history::search_clipboard_history,
            clipboard_history::copy_clipboard_history_entry,
            clipboard_history::clear_clipboard_history,
            window_management::manage_window,
            migration_journal::raycast_read_journal,
            migration_journal::raycast_write_journal,
            migration_journal::raycast_clear_journal,
            window_preferences::get_window_options,
            window_preferences::set_window_options,
            window_management::get_accessibility_permission_status,
            window_management::request_accessibility_permission,
            window_management::open_accessibility_settings,
            shortcut::get_global_shortcut,
            shortcut::set_global_shortcut,
            shortcut::reset_global_shortcut,
            shortcut::get_command_shortcuts,
            shortcut::set_command_shortcut,
            shortcut::remove_command_shortcut,
            system_commands::system_platform,
            system_commands::desktop_capabilities,
            system_commands::open_system_setting,
            system_commands::lock_screen,
            system_commands::run_system_action,
            arithmetic::calculate_arithmetic,
            web::open_web_url,
            web::search_web,
            script_commands::refresh_script_commands,
            script_commands::list_script_commands,
            script_commands::start_script_command,
            script_commands::get_script_command_run,
            script_commands::cancel_script_command,
            script_commands::run_script_command
        ])
        .build(tauri::generate_context!())
        .expect("error while building Prism")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Ready) {
                show_palette(app);
            }
            #[cfg(target_os = "macos")]
            if matches!(event, tauri::RunEvent::Reopen { .. }) {
                show_palette(app);
            }
            if matches!(event, tauri::RunEvent::Exit) {
                dictation::shutdown();
                snippet_expansion::shutdown(app);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::palette_position;
    #[cfg(target_os = "macos")]
    use super::palette_position_appkit;

    #[test]
    fn palette_is_centered_at_one_third_of_the_work_area() {
        assert_eq!(palette_position(100, 60, 1800, 1200, 760, 500), (620, 210));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn appkit_palette_position_uses_one_third_from_the_visual_top() {
        assert_eq!(
            palette_position_appkit(100.0, 60.0, 1800.0, 1200.0, 760.0, 500.0),
            (620.0, 610.0)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn appkit_palette_position_aligns_the_window_to_whole_points() {
        assert_eq!(
            palette_position_appkit(0.0, 0.0, 1511.0, 1001.0, 760.0, 500.0),
            (376.0, 417.0)
        );
    }

    #[test]
    fn palette_position_handles_negative_monitor_origins() {
        assert_eq!(
            palette_position(-1920, 0, 1920, 1080, 760, 500),
            (-1340, 110)
        );
    }
}
