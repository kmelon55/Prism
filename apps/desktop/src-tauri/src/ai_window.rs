use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tauri::Manager;
#[derive(Default)]
pub struct AiWorkspace(pub AtomicBool, AtomicU64);

// The generation cancels obsolete transitions; a reversal starts at the actual current frame.
#[tauri::command]
pub async fn set_ai_workspace(
    window: tauri::WebviewWindow,
    expanded: bool,
    reduce_motion: bool,
) -> Result<(), String> {
    if window.label() != "main" {
        return Err("기본 창에서만 AI 화면을 열 수 있습니다.".into());
    }
    let generation = window
        .state::<AiWorkspace>()
        .1
        .fetch_add(1, Ordering::SeqCst)
        + 1;
    let target = window.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    window
        .run_on_main_thread(move || {
            if !is_current(&target, generation) {
                let _ = tx.send(Ok(None));
                return;
            }
            target
                .state::<AiWorkspace>()
                .0
                .store(expanded, Ordering::Relaxed);
            let _ = target.set_always_on_top(!expanded);
            let _ = tx.send(prepare(&target, expanded).map(Some));
        })
        .map_err(|_| "채팅 창 크기를 변경하지 못했습니다.")?;
    let Some(plan) = rx
        .await
        .map_err(|_| "채팅 창 크기 변경을 완료하지 못했습니다.")??
    else {
        return Ok(());
    };
    let started = std::time::Instant::now();
    let duration = if expanded { 0.42 } else { 0.32 };
    loop {
        if !is_current(&window, generation) {
            return Ok(());
        }
        let progress = if reduce_motion || plan.from == plan.to {
            1.0
        } else {
            (started.elapsed().as_secs_f64() / duration).min(1.0)
        };
        let frame = plan.at(ease_out(progress));
        let target = window.clone();
        let (tx, rx) = tokio::sync::oneshot::channel();
        window
            .run_on_main_thread(move || {
                let result = if is_current(&target, generation) {
                    apply(&target, frame)
                } else {
                    Ok(())
                };
                let _ = tx.send(result);
            })
            .map_err(|_| "채팅 창 크기를 변경하지 못했습니다.")?;
        rx.await
            .map_err(|_| "채팅 창 크기 변경을 완료하지 못했습니다.")??;
        if progress >= 1.0 {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(16)).await;
    }
}
fn is_current(window: &tauri::WebviewWindow, generation: u64) -> bool {
    window.state::<AiWorkspace>().1.load(Ordering::SeqCst) == generation
}
#[derive(Clone, Copy, Debug, PartialEq)]
struct Frame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
struct Transition {
    from: Frame,
    to: Frame,
}
impl Transition {
    fn at(&self, t: f64) -> Frame {
        let lerp = |a, b| a + (b - a) * t;
        Frame {
            x: lerp(self.from.x, self.to.x),
            y: lerp(self.from.y, self.to.y),
            width: lerp(self.from.width, self.to.width),
            height: lerp(self.from.height, self.to.height),
        }
    }
}
// Match CSS cubic-bezier(.22, 1, .36, 1): fast response, long soft settlement, no overshoot.
fn ease_out(progress: f64) -> f64 {
    if progress <= 0.0 {
        return 0.0;
    }
    if progress >= 1.0 {
        return 1.0;
    }
    let (mut low, mut high) = (0.0_f64, 1.0_f64);
    for _ in 0..20 {
        let t = (low + high) / 2.0;
        let x = 3.0 * (1.0 - t).powi(2) * t * 0.22 + 3.0 * (1.0 - t) * t * t * 0.36 + t.powi(3);
        if x < progress {
            low = t;
        } else {
            high = t;
        }
    }
    1.0 - (1.0 - (low + high) / 2.0).powi(3)
}
#[cfg(target_os = "macos")]
fn prepare(window: &tauri::WebviewWindow, expanded: bool) -> Result<Transition, String> {
    use objc2_app_kit::NSWindow;
    let pointer = window
        .ns_window()
        .map_err(|_| "채팅 창을 찾지 못했습니다.")?;
    if pointer.is_null() {
        return Err("채팅 창을 찾지 못했습니다.".into());
    }
    let native = unsafe { &*pointer.cast::<NSWindow>() };
    let screen = native
        .screen()
        .ok_or("현재 화면을 찾지 못했습니다.")?
        .visibleFrame();
    let old = native.frame();
    let (width, height) = workspace_size(expanded, screen.size.width, screen.size.height);
    let from = Frame {
        x: old.origin.x,
        y: old.origin.y,
        width: old.size.width,
        height: old.size.height,
    };
    let to = Frame {
        x: (from.x + (from.width - width) / 2.0)
            .clamp(screen.origin.x, screen.origin.x + screen.size.width - width),
        y: (from.y + from.height - height).clamp(
            screen.origin.y,
            screen.origin.y + screen.size.height - height,
        ),
        width,
        height,
    };
    Ok(Transition { from, to })
}
#[cfg(target_os = "macos")]
fn apply(window: &tauri::WebviewWindow, frame: Frame) -> Result<(), String> {
    use objc2_app_kit::NSWindow;
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let pointer = window
        .ns_window()
        .map_err(|_| "채팅 창을 찾지 못했습니다.")?;
    if pointer.is_null() {
        return Err("채팅 창을 찾지 못했습니다.".into());
    }
    let native = unsafe { &*pointer.cast::<NSWindow>() };
    super::window_glass::without_implicit_animations(|| {
        native.setFrame_display(
            NSRect::new(
                NSPoint::new(frame.x, frame.y),
                NSSize::new(frame.width, frame.height),
            ),
            false,
        );
        super::window_glass::refresh_before_display(native);
        native.displayIfNeeded();
    });
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn prepare(window: &tauri::WebviewWindow, expanded: bool) -> Result<Transition, String> {
    let monitor = window
        .current_monitor()
        .map_err(|_| "현재 화면을 찾지 못했습니다.")?
        .ok_or("현재 화면을 찾지 못했습니다.")?;
    let area = monitor.work_area();
    let old_size = window
        .outer_size()
        .map_err(|_| "채팅 창을 찾지 못했습니다.")?;
    let old_position = window
        .outer_position()
        .map_err(|_| "채팅 창을 찾지 못했습니다.")?;
    let (width, height) = workspace_size(
        expanded,
        area.size.width as f64 / monitor.scale_factor(),
        area.size.height as f64 / monitor.scale_factor(),
    );
    let (width, height) = (
        width * monitor.scale_factor(),
        height * monitor.scale_factor(),
    );
    let from = Frame {
        x: old_position.x as f64,
        y: old_position.y as f64,
        width: old_size.width as f64,
        height: old_size.height as f64,
    };
    let to = Frame {
        x: area.position.x as f64 + (area.size.width as f64 - width) / 2.0,
        y: area.position.y as f64 + (area.size.height as f64 - height) / 2.0,
        width,
        height,
    };
    Ok(Transition { from, to })
}
#[cfg(not(target_os = "macos"))]
fn apply(window: &tauri::WebviewWindow, frame: Frame) -> Result<(), String> {
    window
        .set_size(tauri::PhysicalSize::new(
            frame.width.round() as u32,
            frame.height.round() as u32,
        ))
        .map_err(|_| "채팅 창 크기를 변경하지 못했습니다.")?;
    window
        .set_position(tauri::PhysicalPosition::new(
            frame.x.round() as i32,
            frame.y.round() as i32,
        ))
        .map_err(|_| "채팅 창 위치를 변경하지 못했습니다.".into())
}
fn workspace_size(expanded: bool, available_width: f64, available_height: f64) -> (f64, f64) {
    let (width, height): (f64, f64) = if expanded {
        (1080.0, 760.0)
    } else {
        (760.0, 500.0)
    };
    (
        width.min(available_width.max(1.0)),
        height.min(available_height.max(1.0)),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn easing_responds_quickly_then_settles_without_overshoot() {
        assert_eq!(ease_out(0.0), 0.0);
        assert_eq!(ease_out(1.0), 1.0);
        assert!(ease_out(0.25) > 0.7);
        let samples: Vec<_> = (0..=100).map(|i| ease_out(i as f64 / 100.0)).collect();
        assert!(samples.windows(2).all(|pair| pair[0] <= pair[1]));
        assert!(ease_out(0.9) - ease_out(0.8) < ease_out(0.2) - ease_out(0.1));
    }
    #[test]
    fn reversal_starts_at_the_interrupted_frame() {
        let compact = Frame {
            x: 200.0,
            y: 300.0,
            width: 760.0,
            height: 500.0,
        };
        let expanded = Frame {
            x: 40.0,
            y: 40.0,
            width: 1080.0,
            height: 760.0,
        };
        let opening = Transition {
            from: compact,
            to: expanded,
        };
        let interrupted = opening.at(ease_out(0.2));
        let closing = Transition {
            from: interrupted,
            to: compact,
        };
        assert_eq!(closing.at(0.0), interrupted);
        assert_eq!(closing.at(1.0), compact);
        assert!(closing.at(0.5).width < interrupted.width);
        assert_eq!(
            interrupted.y + interrupted.height,
            compact.y + compact.height
        );
    }
    #[test]
    fn expansion_fits_the_display_and_restores_palette_dimensions() {
        assert_eq!(workspace_size(true, 1440.0, 900.0), (1080.0, 760.0));
        assert_eq!(workspace_size(true, 900.0, 650.0), (900.0, 650.0));
        assert_eq!(workspace_size(false, 1440.0, 900.0), (760.0, 500.0));
    }
}
