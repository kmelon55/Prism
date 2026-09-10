use std::{
    collections::{hash_map::DefaultHasher, HashMap, VecDeque},
    fs,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::UNIX_EPOCH,
};

const MEMORY_CACHE_CAPACITY: usize = 256;
const DISK_CACHE_DIRECTORY: &str = "native-icons-v2";

#[derive(Clone, Default)]
pub struct ApplicationIconCache {
    memory: Arc<Mutex<MemoryCache>>,
    generation: Arc<AtomicU64>,
}

#[derive(Default)]
struct MemoryCache {
    entries: HashMap<String, String>,
    order: VecDeque<String>,
}

impl MemoryCache {
    fn get(&mut self, key: &str) -> Option<String> {
        let value = self.entries.get(key)?.clone();
        self.order.retain(|candidate| candidate != key);
        self.order.push_back(key.to_string());
        Some(value)
    }

    fn insert(&mut self, key: String, value: String) {
        self.order.retain(|candidate| candidate != &key);
        self.order.push_back(key.clone());
        self.entries.insert(key, value);

        while self.entries.len() > MEMORY_CACHE_CAPACITY {
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            }
        }
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }
}

fn cache_key(path: &Path) -> String {
    let mut hasher = DefaultHasher::new();
    path.hash(&mut hasher);
    if let Ok(metadata) = fs::metadata(path) {
        metadata.len().hash(&mut hasher);
        if let Ok(modified) = metadata.modified() {
            modified
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or_default()
                .hash(&mut hasher);
        }
    }
    format!("{:016x}", hasher.finish())
}

fn cache_file(cache_root: &Path, key: &str) -> PathBuf {
    cache_root
        .join(DISK_CACHE_DIRECTORY)
        .join(format!("{key}.txt"))
}

#[cfg(target_os = "macos")]
fn extract_icon(path: &Path) -> Option<String> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use image::{imageops::FilterType, ImageFormat};
    use objc2::runtime::AnyObject;
    use objc2_app_kit::{
        NSBitmapImageFileType, NSBitmapImageRep, NSBitmapImageRepPropertyKey, NSWorkspace,
    };
    use objc2_foundation::{NSDictionary, NSString};
    use std::io::Cursor;

    let full_path = NSString::from_str(path.to_str()?);
    let image = NSWorkspace::sharedWorkspace().iconForFile(&full_path);
    let tiff = image.TIFFRepresentation()?;
    let bitmap = NSBitmapImageRep::imageRepWithData(&tiff)?;
    let properties = NSDictionary::<NSBitmapImageRepPropertyKey, AnyObject>::new();
    let source_png = unsafe {
        bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &properties)
    }?;
    let decoded =
        image::load_from_memory_with_format(&source_png.to_vec(), ImageFormat::Png).ok()?;
    let resized = decoded.resize_exact(128, 128, FilterType::Lanczos3);
    let mut png = Cursor::new(Vec::new());
    resized.write_to(&mut png, ImageFormat::Png).ok()?;

    Some(format!(
        "data:image/png;base64,{}",
        STANDARD.encode(png.into_inner())
    ))
}

#[cfg(not(target_os = "macos"))]
fn extract_icon(_path: &Path) -> Option<String> {
    None
}

async fn load_path(
    cache: ApplicationIconCache,
    cache_root: PathBuf,
    path: PathBuf,
) -> Result<Option<String>, String> {
    let key = cache_key(&path);
    let generation = cache.generation.load(Ordering::Acquire);

    if let Some(icon) = cache
        .memory
        .lock()
        .map_err(|_| "The application icon cache is unavailable.".to_string())?
        .get(&key)
    {
        return Ok(Some(icon));
    }

    let key_for_task = key.clone();
    let task_generation = Arc::clone(&cache.generation);
    let icon = tauri::async_runtime::spawn_blocking(move || {
        let file = cache_file(&cache_root, &key_for_task);
        if let Ok(icon) = fs::read_to_string(&file) {
            if icon.starts_with("data:image/png;base64,") {
                return Some(icon);
            }
        }

        let icon = extract_icon(&path)?;
        if task_generation.load(Ordering::Acquire) != generation {
            return None;
        }
        if let Some(parent) = file.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(file, &icon);
        Some(icon)
    })
    .await
    .map_err(|error| format!("Could not load the application icon: {error}"))?;

    if cache.generation.load(Ordering::Acquire) == generation {
        if let Some(icon) = icon.as_ref() {
            cache
                .memory
                .lock()
                .map_err(|_| "The application icon cache is unavailable.".to_string())?
                .insert(key, icon.clone());
        }
    }

    Ok(icon)
}

pub async fn load_application(
    cache: ApplicationIconCache,
    cache_root: PathBuf,
    target: String,
) -> Result<Option<String>, String> {
    let path = crate::app_catalog::validated_target(&target)?;
    load_path(cache, cache_root, path).await
}

pub async fn load_system(
    cache: ApplicationIconCache,
    cache_root: PathBuf,
    command_id: String,
) -> Result<Option<String>, String> {
    let Some(path) = crate::system_commands::system_icon_target(&command_id)? else {
        return Ok(None);
    };
    load_path(cache, cache_root, path).await
}

pub async fn clear(cache: ApplicationIconCache, cache_root: PathBuf) -> Result<(), String> {
    cache.generation.fetch_add(1, Ordering::AcqRel);
    cache
        .memory
        .lock()
        .map_err(|_| "The application icon cache is unavailable.".to_string())?
        .clear();

    tauri::async_runtime::spawn_blocking(move || {
        let directory = cache_root.join(DISK_CACHE_DIRECTORY);
        match fs::remove_dir_all(directory) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "Could not clear the application icon cache: {error}"
            )),
        }
    })
    .await
    .map_err(|error| format!("Could not clear the application icon cache: {error}"))?
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn extracts_an_installed_application_icon() {
        use base64::{engine::general_purpose::STANDARD, Engine as _};

        let application = crate::app_catalog::discover()
            .into_iter()
            .next()
            .map(|application| PathBuf::from(application.path))
            .expect("macOS should provide at least one installed application");

        let icon = extract_icon(&application)
            .expect("NSWorkspace should return a PNG icon for an application bundle");

        assert!(icon.starts_with("data:image/png;base64,"));
        assert!(icon.len() > "data:image/png;base64,".len());
        let png = STANDARD
            .decode(icon.trim_start_matches("data:image/png;base64,"))
            .expect("the icon should contain valid base64");
        let width = u32::from_be_bytes(png[16..20].try_into().expect("PNG width bytes"));
        let height = u32::from_be_bytes(png[20..24].try_into().expect("PNG height bytes"));
        assert!(width <= 128 && height <= 128, "icon was {width}x{height}");
    }

    #[test]
    fn extracts_an_installed_system_setting_icon() {
        let target = crate::system_commands::system_icon_target("system:settings:notifications")
            .expect("Notifications should be an allowed system command")
            .expect("macOS should provide the Notifications settings bundle");

        let icon =
            extract_icon(&target).expect("NSWorkspace should return the installed settings icon");

        assert!(icon.starts_with("data:image/png;base64,"));
    }

    #[test]
    fn memory_cache_evicts_the_least_recently_used_icon() {
        let mut cache = MemoryCache::default();
        for index in 0..MEMORY_CACHE_CAPACITY {
            cache.insert(index.to_string(), index.to_string());
        }
        assert_eq!(cache.get("0"), Some("0".to_string()));
        cache.insert("overflow".to_string(), "overflow".to_string());

        assert!(cache.entries.contains_key("0"));
        assert!(!cache.entries.contains_key("1"));
    }
}
