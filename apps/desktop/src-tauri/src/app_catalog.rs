use serde::Serialize;
use std::{
    collections::BTreeMap,
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeApplication {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) path: String,
    pub(crate) platform: String,
}

fn home_dir() -> Option<PathBuf> {
    env::var_os(if cfg!(target_os = "windows") {
        "USERPROFILE"
    } else {
        "HOME"
    })
    .map(PathBuf::from)
}

#[cfg(target_os = "macos")]
pub(crate) fn application_roots() -> Vec<PathBuf> {
    let mut roots = vec![
        PathBuf::from("/Applications"),
        PathBuf::from("/System/Applications"),
        // Safari in /Applications can link into the system Cryptex app volume.
        // Resolve this root too so discovery and launch validation agree.
        PathBuf::from("/System/Cryptexes/App/System/Applications"),
    ];
    if let Some(home) = home_dir() {
        roots.push(home.join("Applications"));
    }
    roots
}

#[cfg(target_os = "windows")]
pub(crate) fn application_roots() -> Vec<PathBuf> {
    ["PROGRAMDATA", "APPDATA"]
        .into_iter()
        .filter_map(env::var_os)
        .map(PathBuf::from)
        .map(|root| {
            root.join("Microsoft")
                .join("Windows")
                .join("Start Menu")
                .join("Programs")
        })
        .collect()
}

#[cfg(target_os = "linux")]
pub(crate) fn application_roots() -> Vec<PathBuf> {
    let data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| home_dir().map(|home| home.join(".local/share")));
    let mut roots: Vec<PathBuf> = data_home
        .into_iter()
        .map(|root| root.join("applications"))
        .collect();
    for root in env::split_paths(
        &env::var_os("XDG_DATA_DIRS")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "/usr/local/share:/usr/share".into()),
    ) {
        if root.is_absolute() {
            roots.push(root.join("applications"));
        }
    }
    roots.extend(
        [
            "/var/lib/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications",
        ]
        .map(PathBuf::from),
    );
    if let Some(home) = home_dir() {
        roots.push(home.join(".local/share/flatpak/exports/share/applications"));
    }
    roots
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
pub(crate) fn application_roots() -> Vec<PathBuf> {
    Vec::new()
}

fn application_id(path: &str) -> String {
    let mut id = String::with_capacity(path.len() * 2);
    for byte in path.as_bytes() {
        use std::fmt::Write as _;
        write!(&mut id, "{byte:02x}").expect("writing to a string cannot fail");
    }
    id
}

fn insert_app(apps: &mut BTreeMap<String, NativeApplication>, name: String, path: PathBuf) {
    let display_path = path.to_string_lossy().into_owned();
    let id = application_id(&display_path);
    apps.entry(name.to_lowercase())
        .or_insert(NativeApplication {
            id,
            name,
            path: display_path,
            platform: env::consts::OS.to_string(),
        });
}

#[cfg(target_os = "macos")]
fn scan_root(root: &Path, apps: &mut BTreeMap<String, NativeApplication>) {
    fn visit(root: &Path, depth: usize, apps: &mut BTreeMap<String, NativeApplication>) {
        if depth > 2 {
            return;
        }
        let Ok(entries) = fs::read_dir(root) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) == Some("app") {
                if let Some(name) = path.file_stem().and_then(|value| value.to_str()) {
                    insert_app(apps, name.to_string(), path);
                }
            } else if path.is_dir() {
                visit(&path, depth + 1, apps);
            }
        }
    }

    visit(root, 0, apps);
}

#[cfg(target_os = "windows")]
fn scan_root(root: &Path, apps: &mut BTreeMap<String, NativeApplication>) {
    fn visit(path: &Path, depth: usize, apps: &mut BTreeMap<String, NativeApplication>) {
        if depth > 3 {
            return;
        }
        let Ok(entries) = fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            let candidate = entry.path();
            if candidate.is_dir() {
                visit(&candidate, depth + 1, apps);
            } else if candidate.extension().and_then(|value| value.to_str()) == Some("lnk") {
                if let Some(name) = candidate.file_stem().and_then(|value| value.to_str()) {
                    insert_app(apps, name.to_string(), candidate);
                }
            }
        }
    }
    visit(root, 0, apps);
}

#[cfg(target_os = "linux")]
fn scan_root(root: &Path, apps: &mut BTreeMap<String, NativeApplication>) {
    use gio::prelude::*;
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("desktop") {
            continue;
        }
        // A user-level Hidden entry masks the system entry, even though it is not listed.
        if application_roots()
            .into_iter()
            .take_while(|candidate| candidate != root)
            .any(|candidate| candidate.join(entry.file_name()).is_file())
        {
            continue;
        }
        // GLib handles localized names, OnlyShowIn, NotShowIn, TryExec and desktop entry escaping.
        if let Some(info) = gio::DesktopAppInfo::from_filename(&path) {
            if info.should_show() && !info.is_hidden() {
                insert_app(apps, info.display_name().to_string(), path);
            }
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn scan_root(_root: &Path, _apps: &mut BTreeMap<String, NativeApplication>) {}

pub fn discover() -> Vec<NativeApplication> {
    let mut apps = BTreeMap::new();
    for root in application_roots() {
        scan_root(&root, &mut apps);
    }
    #[cfg(target_os = "windows")]
    if let Ok(entries) = prism_desktop_platform::shell_applications() {
        for (name, target) in entries {
            insert_app(&mut apps, name, PathBuf::from(target));
        }
    }
    apps.into_values().collect()
}

pub(crate) fn validated_target(target: &str) -> Result<PathBuf, String> {
    #[cfg(target_os = "windows")]
    if target.starts_with("shell:AppsFolder\\") {
        if prism_desktop_platform::shell_applications()?
            .iter()
            .any(|(_, candidate)| candidate == target)
        {
            return Ok(PathBuf::from(target));
        }
        return Err("The Windows application is no longer installed.".into());
    }
    let requested = PathBuf::from(target);
    if !requested.is_absolute() || !requested.exists() {
        return Err("The application target no longer exists.".to_string());
    }
    let canonical = requested
        .canonicalize()
        .map_err(|_| "The application target could not be resolved.".to_string())?;
    let allowed = application_roots().into_iter().any(|root| {
        root.canonicalize()
            .map(|candidate| canonical.starts_with(candidate))
            .unwrap_or(false)
    });
    // Flatpak exports may be symlinks to an application deployment outside the export root.
    // Accept only an exact catalog entry; never widen the root to the whole deployment tree.
    #[cfg(target_os = "linux")]
    let allowed = allowed
        || discover()
            .iter()
            .any(|app| Path::new(&app.path).canonicalize().ok().as_ref() == Some(&canonical));
    if !allowed {
        return Err("Prism refused to open a target outside the application catalog.".to_string());
    }
    Ok(canonical)
}

#[cfg(target_os = "macos")]
fn launch_command(target: &Path) -> Command {
    let mut command = Command::new("open");
    command.arg(target);
    command
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn launch_command(_target: &Path) -> Command {
    Command::new("false")
}

pub fn launch(target: &str) -> Result<(), String> {
    let target = validated_target(target)?;
    #[cfg(target_os = "windows")]
    return prism_desktop_platform::open_path(&target, false);
    #[cfg(target_os = "linux")]
    {
        use gio::prelude::*;
        let app = gio::DesktopAppInfo::from_filename(&target)
            .ok_or("The desktop application entry is invalid.")?;
        return app
            .launch(&[], None::<&gio::AppLaunchContext>)
            .map_err(|error| format!("Could not open the application: {error}"));
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    launch_command(&target)
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("Could not open the application: {error}"))
}

pub fn reveal(target: &str) -> Result<(), String> {
    let target = validated_target(target)?;
    #[cfg(target_os = "windows")]
    if target.to_string_lossy().starts_with("shell:AppsFolder\\") {
        return prism_desktop_platform::open_path(Path::new("shell:AppsFolder"), false);
    }

    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg("-R").arg(&target);
        command
    };

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    return prism_desktop_platform::open_path(&target, true);

    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    let mut command = Command::new("false");

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        command
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("Could not reveal the application: {error}"))
    }
}

#[cfg(test)]
mod id_tests {
    use super::application_id;

    #[test]
    fn application_ids_preserve_distinct_non_ascii_paths() {
        let first = application_id("/Applications/한글.app");
        let second = application_id("/Applications/테스트.app");

        assert_ne!(first, second);
        assert_eq!(first, application_id("/Applications/한글.app"));
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn validates_safari_at_its_resolved_system_location() {
        let safari = Path::new("/Applications/Safari.app");
        if !safari.exists() {
            return;
        }

        assert_eq!(
            validated_target(safari.to_str().unwrap()).unwrap(),
            safari.canonicalize().unwrap()
        );
    }

    #[test]
    fn rejects_applications_outside_catalog_roots() {
        let root = env::temp_dir().join(format!(
            "prism-catalog-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root.join("External.app");
        fs::create_dir_all(&app).unwrap();
        let result = validated_target(app.to_str().unwrap());
        fs::remove_dir_all(&root).unwrap();

        assert_eq!(
            result.unwrap_err(),
            "Prism refused to open a target outside the application catalog."
        );
    }

    #[test]
    fn discovers_application_metadata_without_loading_icons() {
        let started = Instant::now();
        let applications = discover();

        assert!(!applications.is_empty());
        eprintln!(
            "discovered {} applications in {:?}",
            applications.len(),
            started.elapsed()
        );
    }
}
