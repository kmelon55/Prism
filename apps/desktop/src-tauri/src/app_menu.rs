//! Keep the launcher running on Cmd+Q, with an explicit menu action to quit.
use tauri::{
    menu::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu},
    AppHandle,
};

pub fn install(app: &AppHandle) -> tauri::Result<()> {
    let menu = Menu::default(app)?;
    let quit = MenuItem::with_id(app, "prism-quit", "Quit Prism", true, None::<&str>)?;
    let application = Submenu::with_items(
        app,
        "Prism",
        true,
        &[
            &PredefinedMenuItem::about(
                app,
                None,
                Some(AboutMetadata {
                    name: Some("Prism".into()),
                    version: Some(app.package_info().version.to_string()),
                    ..Default::default()
                }),
            )?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::services(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, None)?,
            &PredefinedMenuItem::hide_others(app, None)?,
            &PredefinedMenuItem::show_all(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &quit,
        ],
    )?;
    // Tauri's macOS default puts the application menu first. Preserve its Edit,
    // Window and other native menus; replace the predefined Cmd+Q Quit item.
    menu.remove_at(0)?;
    menu.insert(&application, 0)?;
    app.set_menu(menu)?;
    app.on_menu_event(|app, event| {
        if event.id().as_ref() == "prism-quit" {
            app.exit(0);
        }
    });
    // Do not intercept ExitRequested: explicit Quit, logout and updater restart
    // must still use the normal shutdown/cleanup path.
    Ok(())
}
