use super::*;
use std::sync::OnceLock;

fn with_clipboard<T>(
    work: impl FnOnce(&mut arboard::Clipboard) -> Result<T, String>,
) -> Result<T, String> {
    // X11 selection ownership must outlive set_text/set_image. Dropping a temporary
    // Clipboard immediately after copying loses its contents on desktops without a manager.
    static CLIPBOARD: OnceLock<Mutex<Option<arboard::Clipboard>>> = OnceLock::new();
    let mut slot = CLIPBOARD
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| "Clipboard is busy.")?;
    if slot.is_none() {
        *slot = Some(arboard::Clipboard::new().map_err(|_| "Could not access the clipboard.")?);
    }
    work(slot.as_mut().unwrap())
}
fn decode(bytes: &[u8]) -> Result<image::RgbaImage, String> {
    if bytes.len() > MAX_IMAGE_BYTES {
        return Err("Image exceeds clipboard limits.".into());
    }
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_DIMENSION);
    limits.max_image_height = Some(MAX_IMAGE_DIMENSION);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let decoded = reader
        .decode()
        .map_err(|_| "Invalid clipboard image.")?
        .into_rgba8();
    if !valid_dimensions(decoded.width(), decoded.height()) {
        return Err("Image exceeds clipboard limits.".into());
    }
    Ok(decoded)
}
pub(super) fn write(payload: ClipboardPayload) -> Result<Option<isize>, String> {
    with_clipboard(|board| {
        match payload {
            ClipboardPayload::Text(text) => board.set_text(text).map_err(|e| e.to_string())?,
            ClipboardPayload::Image { bytes, .. } => {
                let image = decode(&bytes)?;
                board
                    .set_image(arboard::ImageData {
                        width: image.width() as usize,
                        height: image.height() as usize,
                        bytes: std::borrow::Cow::Owned(image.into_raw()),
                    })
                    .map_err(|e| e.to_string())?;
            }
            ClipboardPayload::Files(_) => return Err(
                "Copying file references is unavailable on this platform. Open the file instead."
                    .into(),
            ),
        }
        Ok(prism_desktop_platform::clipboard_revision())
    })
}
pub(super) fn matches(payload: &ClipboardPayload) -> bool {
    with_clipboard(|board| {
        Ok(match payload {
            ClipboardPayload::Text(text) => board.get_text().is_ok_and(|value| &value == text),
            ClipboardPayload::Image { bytes, .. } => decode(bytes).is_ok_and(|expected| {
                board.get_image().is_ok_and(|actual| {
                    actual.width == expected.width() as usize
                        && actual.height == expected.height() as usize
                        && actual.bytes.as_ref() == expected.as_raw()
                })
            }),
            ClipboardPayload::Files(_) => false,
        })
    })
    .unwrap_or(false)
}
pub(super) fn capture(
    previous: Option<&str>,
) -> Option<(String, Result<Option<ClipboardPayload>, String>)> {
    use std::hash::{Hash, Hasher};
    with_clipboard(|board| {
        if let Ok(text) = board.get_text() {
            let revision = format!("text:{text}");
            return Ok((
                revision.clone(),
                Ok((previous != Some(&revision) && should_capture(&text))
                    .then_some(ClipboardPayload::Text(text))),
            ));
        }
        let image = board
            .get_image()
            .map_err(|_| "No supported clipboard content.")?;
        if image.width > MAX_IMAGE_DIMENSION as usize
            || image.height > MAX_IMAGE_DIMENSION as usize
            || !valid_dimensions(image.width as u32, image.height as u32)
        {
            return Ok((
                "oversized-image".into(),
                Err("Image exceeds clipboard limits.".into()),
            ));
        }
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        image.bytes.hash(&mut hash);
        let revision = format!("image:{}:{}:{}", image.width, image.height, hash.finish());
        if previous == Some(&revision) {
            return Ok((revision, Ok(None)));
        }
        let decoded = image::RgbaImage::from_raw(
            image.width as u32,
            image.height as u32,
            image.bytes.into_owned(),
        )
        .ok_or("Invalid clipboard image.")?;
        let mut output = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(decoded)
            .write_to(&mut output, image::ImageFormat::Png)
            .map_err(|e| e.to_string())?;
        let bytes = output.into_inner();
        let payload = if bytes.len() > MAX_IMAGE_BYTES {
            Err("Image exceeds 8 MB. Copy a smaller image to save it in history.".into())
        } else {
            Ok(Some(ClipboardPayload::Image {
                bytes,
                mime_type: "image/png".into(),
                width: image.width as u32,
                height: image.height as u32,
            }))
        };
        Ok((revision, payload))
    })
    .ok()
}
