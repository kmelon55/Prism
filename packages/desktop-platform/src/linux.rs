use crate::{Bounds, Capabilities, PowerAction, TargetWindow};
use std::{path::Path, time::Duration};
use x11rb::{
    connection::Connection,
    protocol::{
        dpms::ConnectionExt as _, randr::ConnectionExt as _, xproto::*, xtest::ConnectionExt as _,
    },
    rust_connection::RustConnection,
};

fn err(error: impl std::fmt::Display) -> String {
    format!("Linux desktop request failed: {error}")
}
fn wayland() -> bool {
    std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v.eq_ignore_ascii_case("wayland"))
        || std::env::var_os("WAYLAND_DISPLAY").is_some()
}
fn desktop() -> String {
    std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_ascii_lowercase()
}
pub fn capabilities() -> Capabilities {
    crate::linux_capabilities(wayland(), std::env::var_os("DISPLAY").is_some(), &desktop())
}
struct X11 {
    connection: RustConnection,
    root: Window,
}
impl X11 {
    fn connect() -> Result<Self, String> {
        if wayland() {
            return Err("Window control and automatic paste are unavailable in this Wayland session. Use Copy.".into());
        }
        let (connection, screen) = x11rb::connect(None).map_err(err)?;
        let root = connection.setup().roots[screen].root;
        Ok(Self { connection, root })
    }
    fn atom(&self, name: &str) -> Result<Atom, String> {
        Ok(self
            .connection
            .intern_atom(false, name.as_bytes())
            .map_err(err)?
            .reply()
            .map_err(err)?
            .atom)
    }
    fn property(&self, window: Window, name: &str) -> Result<Vec<u32>, String> {
        let reply = self
            .connection
            .get_property(false, window, self.atom(name)?, AtomEnum::ANY, 0, 1024)
            .map_err(err)?
            .reply()
            .map_err(err)?;
        Ok(reply.value32().map(|v| v.collect()).unwrap_or_default())
    }
    fn validate(&self, target: TargetWindow) -> Result<Window, String> {
        let window = u32::try_from(target.id).map_err(err)?;
        let pid = self
            .property(window, "_NET_WM_PID")?
            .first()
            .copied()
            .unwrap_or(0);
        if window == 0 || pid == 0 || pid != target.pid || pid == std::process::id() {
            return Err("The target window has changed or cannot be identified.".into());
        }
        self.connection
            .get_window_attributes(window)
            .map_err(err)?
            .reply()
            .map_err(err)?;
        Ok(window)
    }
    fn message(&self, target: Window, name: &str, data: [u32; 5]) -> Result<(), String> {
        let event = ClientMessageEvent::new(32, target, self.atom(name)?, data);
        self.connection
            .send_event(
                false,
                self.root,
                EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
                event,
            )
            .map_err(err)?
            .check()
            .map_err(err)?;
        self.connection.flush().map_err(err)
    }
    fn extents(&self, window: Window) -> [f64; 4] {
        let values = self
            .property(window, "_NET_FRAME_EXTENTS")
            .unwrap_or_default();
        std::array::from_fn(|i| values.get(i).copied().unwrap_or(0) as f64)
    }
    fn bounds(&self, target: TargetWindow) -> Result<Bounds, String> {
        let window = self.validate(target)?;
        let geometry = self
            .connection
            .get_geometry(window)
            .map_err(err)?
            .reply()
            .map_err(err)?;
        let point = self
            .connection
            .translate_coordinates(window, self.root, 0, 0)
            .map_err(err)?
            .reply()
            .map_err(err)?;
        let [left, right, top, bottom] = self.extents(window);
        Ok(Bounds {
            x: point.dst_x as f64 - left,
            y: point.dst_y as f64 - top,
            width: geometry.width as f64 + left + right,
            height: geometry.height as f64 + top + bottom,
        })
    }
}
pub fn foreground() -> Result<TargetWindow, String> {
    let x = X11::connect()?;
    let window = x
        .property(x.root, "_NET_ACTIVE_WINDOW")?
        .first()
        .copied()
        .unwrap_or(0);
    let pid = x
        .property(window, "_NET_WM_PID")?
        .first()
        .copied()
        .unwrap_or(0);
    let target = TargetWindow {
        id: window as usize,
        pid,
    };
    x.validate(target)?;
    Ok(target)
}
pub fn bounds(target: TargetWindow) -> Result<Bounds, String> {
    X11::connect()?.bounds(target)
}
pub fn set_bounds(target: TargetWindow, rect: Bounds) -> Result<Bounds, String> {
    if !rect.valid() {
        return Err("Invalid window bounds.".into());
    }
    let x = X11::connect()?;
    let window = x.validate(target)?;
    let supported = x.property(x.root, "_NET_SUPPORTED")?;
    if !supported.contains(&x.atom("_NET_MOVERESIZE_WINDOW")?) {
        return Err("This window manager does not support window positioning.".into());
    }
    x.message(
        window,
        "_NET_WM_STATE",
        [
            0,
            x.atom("_NET_WM_STATE_MAXIMIZED_HORZ")?,
            x.atom("_NET_WM_STATE_MAXIMIZED_VERT")?,
            2,
            0,
        ],
    )?;
    let [left, right, top, bottom] = x.extents(window);
    x.message(
        window,
        "_NET_MOVERESIZE_WINDOW",
        [
            1 | (15 << 8) | (2 << 12),
            rect.x.round() as i32 as u32,
            rect.y.round() as i32 as u32,
            (rect.width - left - right).max(1.0).round() as u32,
            (rect.height - top - bottom).max(1.0).round() as u32,
        ],
    )?;
    let mut observed = x.bounds(target)?;
    for _ in 0..10 {
        std::thread::sleep(Duration::from_millis(20));
        observed = x.bounds(target)?;
        if (observed.x - rect.x).abs() <= 2.0
            && (observed.y - rect.y).abs() <= 2.0
            && (observed.width - rect.width).abs() <= 2.0
            && (observed.height - rect.height).abs() <= 2.0
        {
            break;
        }
    }
    Ok(observed)
}
pub fn activate(target: TargetWindow) -> Result<(), String> {
    let x = X11::connect()?;
    let window = x.validate(target)?;
    x.message(
        window,
        "_NET_ACTIVE_WINDOW",
        [2, x11rb::CURRENT_TIME, 0, 0, 0],
    )
}
pub fn work_areas() -> Result<Vec<Bounds>, String> {
    let x = X11::connect()?;
    let desktop = x
        .property(x.root, "_NET_CURRENT_DESKTOP")?
        .first()
        .copied()
        .unwrap_or(0) as usize;
    let work = x.property(x.root, "_NET_WORKAREA")?;
    let work = work.get(desktop.saturating_mul(4)..desktop.saturating_mul(4).saturating_add(4));
    let monitors = x
        .connection
        .randr_get_monitors(x.root, true)
        .map_err(err)?
        .reply()
        .map_err(err)?;
    let areas: Vec<_> = monitors
        .monitors
        .into_iter()
        .map(|m| {
            let mut b = Bounds {
                x: m.x as f64,
                y: m.y as f64,
                width: m.width as f64,
                height: m.height as f64,
            };
            if let Some(w) = work {
                let left = b.x.max(w[0] as i32 as f64);
                let top = b.y.max(w[1] as i32 as f64);
                let right = (b.x + b.width).min(w[0] as i32 as f64 + w[2] as f64);
                let bottom = (b.y + b.height).min(w[1] as i32 as f64 + w[3] as f64);
                if right > left && bottom > top {
                    b = Bounds {
                        x: left,
                        y: top,
                        width: right - left,
                        height: bottom - top,
                    };
                }
            }
            b
        })
        .filter(|b| b.valid())
        .collect();
    if areas.is_empty() {
        Err("No desktop monitors are available.".into())
    } else {
        Ok(areas)
    }
}
pub fn clipboard_revision() -> Option<isize> {
    let x = X11::connect().ok()?;
    let atom = x.atom("CLIPBOARD").ok()?;
    let owner = x
        .connection
        .get_selection_owner(atom)
        .ok()?
        .reply()
        .ok()?
        .owner;
    Some(owner as isize)
}
pub fn modifiers_down() -> bool {
    let Ok(x) = X11::connect() else {
        return true;
    };
    let Ok(cookie) = x.connection.query_pointer(x.root) else {
        return true;
    };
    let Ok(pointer) = cookie.reply() else {
        return true;
    };
    (u16::from(pointer.mask) & 0xff) != 0
}
pub fn paste(target: TargetWindow) -> Result<(), String> {
    if foreground()? != target {
        return Err("The target window changed. The item remains copied.".into());
    }
    if modifiers_down() {
        return Err("Release modifier keys and try again. The item remains copied.".into());
    }
    let x = X11::connect()?;
    let setup = x.connection.setup();
    let first = setup.min_keycode;
    let keys = x
        .connection
        .get_keyboard_mapping(first, setup.max_keycode - first + 1)
        .map_err(err)?
        .reply()
        .map_err(err)?;
    let find = |symbol| {
        keys.keysyms
            .chunks(keys.keysyms_per_keycode as usize)
            .position(|row| row.first() == Some(&symbol))
            .map(|i| first + i as u8)
            .ok_or("The keyboard layout has no paste key.")
    };
    let control = find(0xffe3)?;
    let v = find(0x76)?;
    for (event, key) in [
        (KEY_PRESS_EVENT, control),
        (KEY_PRESS_EVENT, v),
        (KEY_RELEASE_EVENT, v),
        (KEY_RELEASE_EVENT, control),
    ] {
        x.connection
            .xtest_fake_input(event, key, x11rb::CURRENT_TIME, x.root, 0, 0, 0)
            .map_err(err)?
            .check()
            .map_err(err)?;
    }
    x.connection.flush().map_err(err)
}
pub fn open_path(path: &Path, reveal: bool) -> Result<(), String> {
    if reveal {
        // FileManager1 selects the file; desktops without it still open the containing folder.
        if let Ok(connection) = zbus::blocking::Connection::session() {
            if let Ok(proxy) = zbus::blocking::Proxy::new(
                &connection,
                "org.freedesktop.FileManager1",
                "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1",
            ) {
                let uri = file_uri(path)?;
                if proxy
                    .call::<_, _, ()>("ShowItems", &(vec![uri], ""))
                    .is_ok()
                {
                    return Ok(());
                }
            }
        }
    }
    let destination = if reveal {
        path.parent().unwrap_or(path)
    } else {
        path
    };
    // Canonical absolute paths cannot be interpreted as xdg-open options.
    std::process::Command::new("xdg-open")
        .arg(destination.canonicalize().map_err(err)?)
        .spawn()
        .map_err(err)?;
    Ok(())
}
fn file_uri(path: &Path) -> Result<String, String> {
    use std::os::unix::ffi::OsStrExt;
    let mut uri = String::from("file://");
    for byte in path.canonicalize().map_err(err)?.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(byte) {
            uri.push(*byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    Ok(uri)
}
pub fn power(action: PowerAction) -> Result<(), String> {
    match action {
        PowerAction::SleepDisplays => {
            let x = X11::connect()?;
            if !x
                .connection
                .dpms_capable()
                .map_err(err)?
                .reply()
                .map_err(err)?
                .capable
            {
                return Err("This display server does not support display sleep.".into());
            }
            x.connection
                .dpms_force_level(x11rb::protocol::dpms::DPMSMode::OFF)
                .map_err(err)?
                .check()
                .map_err(err)?;
            x.connection.flush().map_err(err)
        }
        PowerAction::LogOut => {
            let connection = zbus::blocking::Connection::session().map_err(err)?;
            let desktop = desktop();
            if desktop.contains("gnome") {
                let proxy = zbus::blocking::Proxy::new(
                    &connection,
                    "org.gnome.SessionManager",
                    "/org/gnome/SessionManager",
                    "org.gnome.SessionManager",
                )
                .map_err(err)?;
                proxy.call::<_, _, ()>("Logout", &(0u32,)).map_err(err)
            } else if desktop.contains("kde") {
                let proxy = zbus::blocking::Proxy::new(
                    &connection,
                    "org.kde.Shutdown",
                    "/Shutdown",
                    "org.kde.Shutdown",
                )
                .map_err(err)?;
                proxy.call::<_, _, ()>("logout", &()).map_err(err)
            } else {
                Err("Graceful logout is supported on GNOME and KDE sessions.".into())
            }
        }
        _ => {
            let connection = zbus::blocking::Connection::system().map_err(err)?;
            let proxy = zbus::blocking::Proxy::new(
                &connection,
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
            )
            .map_err(err)?;
            let method = match action {
                PowerAction::Sleep => "Suspend",
                PowerAction::Restart => "Reboot",
                PowerAction::ShutDown => "PowerOff",
                _ => unreachable!(),
            };
            proxy.call::<_, _, ()>(method, &(true,)).map_err(err)
        }
    }
}
