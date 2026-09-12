use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};

pub const MAX_IMAGE_URL: usize = 1_400_000;
pub const MAX_SESSION_IMAGES: usize = 4;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatImage {
    pub data_url: String,
}

pub fn validate_image(image: &ChatImage) -> Result<(), String> {
    let encoded = image
        .data_url
        .strip_prefix("data:image/jpeg;base64,")
        .ok_or("올바른 화면 캡처가 아닙니다.")?;
    if image.data_url.len() > MAX_IMAGE_URL {
        return Err("화면 캡처가 너무 큽니다.".into());
    }
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| "화면 캡처를 읽지 못했습니다.")?;
    let reader =
        image::ImageReader::with_format(std::io::Cursor::new(bytes), image::ImageFormat::Jpeg);
    let (width, height) = reader
        .into_dimensions()
        .map_err(|_| "화면 캡처를 읽지 못했습니다.")?;
    if width == 0 || height == 0 || width > 1600 || height > 1600 {
        return Err("화면 캡처 크기가 올바르지 않습니다.".into());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
static CAPTURING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[cfg(target_os = "macos")]
fn encode_capture(path: &std::path::Path) -> Result<ChatImage, String> {
    let size = std::fs::metadata(path)
        .map_err(|_| "화면 캡처를 읽지 못했습니다.")?
        .len();
    if size > 40 * 1024 * 1024 {
        return Err("선택한 영역이 너무 큽니다. 더 작은 영역을 선택하세요.".into());
    }
    let mut reader = image::ImageReader::open(path)
        .map_err(|_| "화면 캡처를 열지 못했습니다.")?
        .with_guessed_format()
        .map_err(|_| "화면 캡처 형식을 읽지 못했습니다.")?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(20000);
    limits.max_image_height = Some(20000);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let decoded = reader
        .decode()
        .map_err(|_| "선택한 영역을 처리하지 못했습니다. 더 작은 영역을 선택하세요.")?;
    let resized = decoded.thumbnail(1600, 1600).to_rgb8();
    let mut bytes = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 85)
        .encode_image(&resized)
        .map_err(|_| "화면 캡처를 압축하지 못했습니다.")?;
    let image = ChatImage {
        data_url: format!("data:image/jpeg;base64,{}", STANDARD.encode(bytes)),
    };
    validate_image(&image)?;
    Ok(image)
}

pub fn is_capturing() -> bool {
    #[cfg(target_os = "macos")]
    {
        CAPTURING.try_lock().is_err()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Invoked only by an explicit command. The system selector owns Escape and the crosshair.
#[tauri::command]
pub async fn ai_capture_region(app: tauri::AppHandle) -> Result<Option<ChatImage>, String> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Err("화면 영역 캡처는 macOS에서 사용할 수 있습니다.".into())
    }
    #[cfg(target_os = "macos")]
    {
        use tauri::Manager;
        let _capture = CAPTURING
            .try_lock()
            .map_err(|_| "이미 화면 영역을 선택하고 있습니다.")?;
        let directory = tempfile::Builder::new()
            .prefix("prism-capture-")
            .tempdir()
            .map_err(|_| "화면 캡처를 준비하지 못했습니다.")?;
        let path = directory.path().join("region.png");
        let window = app
            .get_webview_window("main")
            .ok_or("Prism 창을 찾지 못했습니다.")?;
        window.hide().map_err(|_| "Prism 창을 숨기지 못했습니다.")?;
        let result = async {
            tokio::time::sleep(std::time::Duration::from_millis(180)).await;
            let mut command = tokio::process::Command::new("/usr/sbin/screencapture");
            command.args(["-i", "-s", "-x", "-t", "png"]).arg(&path)
                .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null()).kill_on_drop(true);
            let status = tokio::time::timeout(std::time::Duration::from_secs(120), command.status())
                .await.map_err(|_| "화면 선택 시간이 지났습니다. 다시 실행하세요.")?
                .map_err(|_| "화면 영역 선택을 시작하지 못했습니다.")?;
            // Escape produces no file. Other failures are surfaced when capture exits unsuccessfully.
            if !path.exists() {
                #[link(name = "CoreGraphics", kind = "framework")]
                extern "C" { fn CGPreflightScreenCaptureAccess() -> bool; }
                return if status.success() || unsafe { CGPreflightScreenCaptureAccess() } { Ok(None) } else { Err("화면을 캡처하지 못했습니다. macOS 시스템 설정에서 Prism의 화면 기록 권한을 확인하세요.".into()) };
            }
            tauri::async_runtime::spawn_blocking(move || { let _directory = directory; encode_capture(&path).map(Some) })
                .await.map_err(|_| "화면 캡처 처리가 중단되었습니다.".to_string())?
        }.await;
        drop(_capture);
        crate::show_palette(&app);
        result
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub fn fixture() -> ChatImage {
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new(&mut bytes)
            .encode_image(&image::RgbImage::new(2, 2))
            .unwrap();
        ChatImage {
            data_url: format!("data:image/jpeg;base64,{}", STANDARD.encode(bytes)),
        }
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn compresses_large_regions_and_rejects_invalid_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("region.png");
        image::RgbImage::new(2400, 900).save(&path).unwrap();
        let capture = encode_capture(&path).unwrap();
        validate_image(&capture).unwrap();
        let bytes = STANDARD
            .decode(
                capture
                    .data_url
                    .strip_prefix("data:image/jpeg;base64,")
                    .unwrap(),
            )
            .unwrap();
        let decoded = image::load_from_memory(&bytes).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (1600, 600));
        std::fs::write(&path, b"not an image").unwrap();
        assert!(encode_capture(&path).is_err());
    }
    #[test]
    fn accepts_small_jpeg_and_rejects_external_or_invalid_images() {
        validate_image(&fixture()).unwrap();
        for data_url in [
            "https://example.com/private.jpg",
            "data:image/jpeg;base64,AAAA",
            "data:image/svg+xml;base64,AAAA",
        ] {
            assert!(validate_image(&ChatImage {
                data_url: data_url.into()
            })
            .is_err());
        }
        assert!(validate_image(&ChatImage {
            data_url: format!("data:image/jpeg;base64,{}", "A".repeat(MAX_IMAGE_URL))
        })
        .is_err());
    }
}
