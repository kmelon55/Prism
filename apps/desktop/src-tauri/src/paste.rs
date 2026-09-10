use std::sync::atomic::{AtomicBool, Ordering};
use tauri::Manager;
static PASTING: AtomicBool = AtomicBool::new(false);
pub(crate) struct PasteGuard;
impl PasteGuard {
    pub(crate) fn acquire() -> Result<Self, String> {
        if PASTING.swap(true, Ordering::AcqRel) {
            return Err("붙여넣기가 진행 중입니다.".into());
        }
        Ok(Self)
    }
}
impl Drop for PasteGuard {
    fn drop(&mut self) {
        PASTING.store(false, Ordering::Release);
    }
}
async fn on_main<T: Send + 'static>(
    app: &tauri::AppHandle,
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let _ = tx.send(work());
    })
    .map_err(|_| "붙여넣기를 준비하지 못했습니다.")?;
    rx.await
        .map_err(|_| "붙여넣기 작업이 중단되었습니다.".to_string())?
}
pub async fn paste_text(app: tauri::AppHandle, text: String) -> Result<(), String> {
    paste_payload(app, crate::clipboard_history::ClipboardPayload::Text(text)).await
}
pub(crate) async fn paste_payload(
    app: tauri::AppHandle,
    payload: crate::clipboard_history::ClipboardPayload,
) -> Result<(), String> {
    let guard = PasteGuard::acquire()?;
    let prepared = tauri::async_runtime::spawn_blocking(move || {
        crate::clipboard_history::PreparedClipboardPayload::new(payload)
    })
    .await
    .map_err(|_| "클립보드 항목을 준비하지 못했습니다.".to_string())??;
    paste_prepared_payload(app, prepared, guard).await
}

pub(crate) async fn paste_prepared_payload(
    app: tauri::AppHandle,
    payload: crate::clipboard_history::PreparedClipboardPayload,
    _guard: PasteGuard,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication, NSWorkspace};
        let host = app.clone();
        let prepared = on_main(&app, move || {
            if !unsafe { accessibility_sys::AXIsProcessTrusted() } {
                return Err("붙여넣기에는 손쉬운 사용 권한이 필요합니다. 설정에서 허용하거나 복사를 사용하세요.".into());
            }
            let pid=host.state::<crate::window_management::WindowManager>().target_pid.load(Ordering::Acquire);
            if pid<=0 || pid==std::process::id() as i32 || !crate::window_management::paste_target_matches(&host,pid) {
                return Err("붙여넣을 창이 바뀌었거나 없습니다. 대상 창에서 Prism을 다시 열거나 복사를 사용하세요.".into());
            }
            let target=NSRunningApplication::runningApplicationWithProcessIdentifier(pid).filter(|a|!a.isTerminated()).ok_or("붙여넣을 앱이 종료되었습니다. 복사를 사용하세요.")?;
            let revision = crate::clipboard_history::write_prepared_clipboard_payload(payload)?
                .ok_or("클립보드 변경 상태를 확인하지 못했습니다.")?;
            if let Some(window)=host.get_webview_window("main"){window.hide().map_err(|_|"Prism 창을 숨기지 못했습니다.")?;}
            if !target.activateWithOptions(NSApplicationActivationOptions::empty()) {
                if let Some(window)=host.get_webview_window("main"){let _=window.show();let _=window.set_focus();}
                return Err("대상 앱을 활성화하지 못했습니다. 항목은 클립보드에 복사했습니다.".into());
            }
            Ok((pid, revision))
        }).await;
        let (pid, revision) = prepared?;
        // Activation is asynchronous. Never inject into an unrelated foreground application.
        let mut activated = false;
        for _ in 0..8 {
            tokio::time::sleep(std::time::Duration::from_millis(40)).await;
            let host = app.clone();
            activated = on_main(&app, move || {
                Ok(host
                    .state::<crate::window_management::WindowManager>()
                    .target_pid
                    .load(Ordering::Acquire)
                    == pid
                    && NSWorkspace::sharedWorkspace()
                        .frontmostApplication()
                        .is_some_and(|a| a.processIdentifier() == pid))
            })
            .await?;
            if activated {
                break;
            }
        }
        let host = app.clone();
        let result = if activated {
            on_main(&app, move || {
                if !crate::window_management::paste_target_matches(&host, pid)
                    || !NSWorkspace::sharedWorkspace()
                        .frontmostApplication()
                        .is_some_and(|a| a.processIdentifier() == pid)
                {
                    return Err(
                        "대상 앱이 바뀌어 붙여넣기를 중단했습니다. 항목은 복사했습니다.".into(),
                    );
                }
                paste_if_revision_matches(
                    revision,
                    || objc2_app_kit::NSPasteboard::generalPasteboard().changeCount(),
                    || unsafe { post_paste(pid) },
                )
            })
            .await
        } else {
            Err("대상 앱으로 돌아가지 못했습니다. 항목은 클립보드에 복사했습니다.".into())
        };
        if result.is_err() {
            let host = app.clone();
            let _ = on_main(&app, move || {
                if let Some(w) = host.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
                Ok(())
            })
            .await;
        }
        result
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, payload);
        Err("붙여넣기는 현재 macOS에서 지원합니다. 복사를 사용하세요.".into())
    }
}
// Read once, immediately before posting; never retry or restore over another clipboard owner.
fn paste_if_revision_matches(
    expected: isize,
    current: impl FnOnce() -> isize,
    post: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    if current() != expected {
        return Err(
            "클립보드가 변경되어 붙여넣기를 중단했습니다. 항목을 다시 선택해 주세요.".into(),
        );
    }
    post()
}

#[cfg(target_os = "macos")]
unsafe fn post_paste(pid: i32) -> Result<(), String> {
    use std::ffi::c_void;
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn CGEventCreateKeyboardEvent(source: *const c_void, key: u16, down: bool) -> *mut c_void;
        fn CGEventSetFlags(event: *const c_void, flags: u64);
        fn CGEventPostToPid(pid: i32, event: *const c_void);
    }
    let down = CGEventCreateKeyboardEvent(std::ptr::null(), 9, true);
    let up = CGEventCreateKeyboardEvent(std::ptr::null(), 9, false);
    if down.is_null() || up.is_null() {
        if !down.is_null() {
            core_foundation_sys::base::CFRelease(down);
        }
        if !up.is_null() {
            core_foundation_sys::base::CFRelease(up);
        }
        return Err("붙여넣기 키를 만들지 못했습니다. 항목은 복사했습니다.".into());
    }
    for event in [down, up] {
        CGEventSetFlags(event, 1 << 20);
        CGEventPostToPid(pid, event);
        core_foundation_sys::base::CFRelease(event);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::paste_if_revision_matches;
    use std::cell::Cell;

    #[test]
    fn unchanged_write_revision_posts_once_after_reading_current_revision() {
        let order = Cell::new(0);
        let result = paste_if_revision_matches(
            42,
            || {
                assert_eq!(order.replace(1), 0);
                42
            },
            || {
                assert_eq!(order.replace(2), 1);
                Ok(())
            },
        );
        assert!(result.is_ok());
        assert_eq!(order.get(), 2);
    }

    #[test]
    fn clipboard_replaced_during_activation_never_posts_or_overwrites() {
        let board_revision = Cell::new(42);
        let acknowledged = board_revision.get();
        // An unrelated owner copies while Prism waits for activation.
        board_revision.set(43);
        let result = paste_if_revision_matches(
            acknowledged,
            || board_revision.get(),
            || panic!("must not paste unrelated clipboard content"),
        );
        assert!(result.unwrap_err().contains("클립보드가 변경"));
        assert_eq!(board_revision.get(), 43);
    }

    #[test]
    fn posting_error_is_returned_without_retry() {
        let posts = Cell::new(0);
        let result = paste_if_revision_matches(
            42,
            || 42,
            || {
                posts.set(posts.get() + 1);
                Err("post failed".into())
            },
        );
        assert_eq!(result.unwrap_err(), "post failed");
        assert_eq!(posts.get(), 1);
    }
}
