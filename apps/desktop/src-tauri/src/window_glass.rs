//! Native glass lives below the webview; blur radius and CSS tint are independent.
//! The CSS background is the only tint/opacity layer; there is no opaque material.

use objc2::{
    msg_send,
    rc::Retained,
    runtime::{AnyClass, AnyObject},
    sel, MainThreadMarker,
};
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSColor, NSGlassEffectView, NSGlassEffectViewStyle,
    NSUserInterfaceItemIdentification, NSView, NSVisualEffectBlendingMode, NSVisualEffectMaterial,
    NSVisualEffectState, NSVisualEffectView, NSWindow, NSWindowOrderingMode,
};
use objc2_foundation::{
    ns_string, NSArray, NSNumber, NSObject, NSObjectNSKeyValueCoding, NSObjectProtocol, NSString,
};
use objc2_quartz_core::CALayer;
use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex},
    time::Duration,
};

const GLASS_ID: &str = "dev.prism.clear-glass:";
// Keep in sync with settings/appearance.ts; legacy callers cannot exceed this.
const MAX_BACKGROUND_BLUR: u8 = 32;
static REFRESH_REQUESTS: LazyLock<Mutex<HashMap<String, u64>>> = LazyLock::new(Mutex::default);

// AppKit owns the backdrop and its lifecycle. Radius is an internal CAFilter
// input: feature-detect it and catch KVC exceptions so future macOS versions
// retain standard native glass instead of crashing. Never fade the effect view;
// doing so mixes sharp desktop text back into the blurred result.
fn set_radius(layer: &CALayer, radius: f64) -> bool {
    let mut changed = false;
    unsafe {
        if let Some(filters) = layer.filters() {
            let mut replacement: Vec<Retained<AnyObject>> = filters.iter().collect();
            for (index, filter) in filters.iter().enumerate() {
                let object: &NSObject = &*(&*filter as *const AnyObject as *const NSObject);
                if !object.respondsToSelector(sel!(inputKeys))
                    || !object.respondsToSelector(sel!(copy))
                {
                    continue;
                }
                let keys: Option<Retained<NSArray<NSString>>> = msg_send![object, inputKeys];
                let Some(keys) = keys else { continue };
                let key = if keys.containsObject(ns_string!("inputBlurRadius")) {
                    ns_string!("inputBlurRadius")
                } else if keys.containsObject(ns_string!("inputRadius")) {
                    ns_string!("inputRadius")
                } else {
                    continue;
                };
                // Mutating the existing filter does not invalidate Core Animation's
                // render cache. Copy it, update the radius, then replace the array.
                let copy: Retained<NSObject> = msg_send![object, copy];
                copy.setValue_forKey(Some(&NSNumber::numberWithDouble(radius)), key);
                replacement[index] = Retained::cast_unchecked(copy);
                changed = true;
            }
            if changed {
                layer.setFilters(Some(&NSArray::from_retained_slice(&replacement)));
            }
        }
        if let Some(children) = layer.sublayers() {
            for child in children {
                changed |= set_radius(&child, radius);
            }
        }
    }
    changed
}

fn refresh(view: &NSView) {
    let Some(identifier) = view.identifier() else {
        return;
    };
    let identifier = identifier.to_string();
    let Some(radius) = identifier
        .strip_prefix(GLASS_ID)
        .and_then(|value| value.parse::<f64>().ok())
    else {
        return;
    };
    let _ = objc2::exception::catch(std::panic::AssertUnwindSafe(|| {
        view.layoutSubtreeIfNeeded();
        if let Some(layer) = view.layer() {
            set_radius(&layer, radius);
        }
    }));
}

// SwiftUI-backed glass creates its filters after attaching to a visible window.
// Retry briefly after appearance/resize, coalescing slider and resize bursts per
// window. No polling remains when idle; each retry reads the latest radius.
pub fn schedule_refresh(window: &tauri::WebviewWindow) {
    let window = window.clone();
    let label = window.label().to_owned();
    let generation = {
        let mut requests = REFRESH_REQUESTS.lock().unwrap();
        let entry = requests.entry(label.clone()).or_default();
        *entry += 1;
        *entry
    };
    tauri::async_runtime::spawn(async move {
        for delay in [0, 16, 64, 160, 400] {
            tokio::time::sleep(Duration::from_millis(delay)).await;
            if REFRESH_REQUESTS.lock().unwrap().get(&label) != Some(&generation) {
                return;
            }
            if window
                .with_webview(|webview| {
                    let ptr = webview.inner().cast::<NSView>();
                    if ptr.is_null() {
                        return;
                    }
                    if let Some(parent) = unsafe { (&*ptr).superview() } {
                        for child in parent.subviews() {
                            if child
                                .identifier()
                                .is_some_and(|id| id.to_string().starts_with(GLASS_ID))
                            {
                                refresh(&child);
                            }
                        }
                    }
                })
                .is_err()
            {
                return;
            }
        }
    });
}

pub async fn apply(window: &tauri::WebviewWindow, strength: u8) -> Result<(), String> {
    let strength = strength.min(MAX_BACKGROUND_BLUR);
    let effect_window = window.clone();
    let (send, receive) = tokio::sync::oneshot::channel::<Result<(), String>>();
    window
        .with_webview(move |webview| {
            let result = (|| {
                let mtm = MainThreadMarker::new().ok_or("Glass requires the main thread")?;
                // Tauri 2.11's set_effects(None) does not clear macOS vibrancy.
                // Its apply path also adds another view on every update. Remove
                // all legacy tagged materials before touching our single layer.
                while window_vibrancy::clear_vibrancy(&effect_window)
                    .map_err(|error| error.to_string())?
                {}
                let view_ptr = webview.inner().cast::<NSView>();
                let window_ptr = webview.ns_window().cast::<NSWindow>();
                if view_ptr.is_null() || window_ptr.is_null() {
                    return Err("Prism could not find its native glass surface".into());
                }
                // Tauri owns these handles for the duration of with_webview.
                let (view, native) = unsafe { (&*view_ptr, &*window_ptr) };
                native.setOpaque(false);
                native.setBackgroundColor(Some(&NSColor::clearColor()));
                let parent = unsafe { view.superview() }
                    .ok_or("Prism could not find the webview container")?;
                let identifier = NSString::from_str(&format!("{GLASS_ID}{strength}"));
                let existing = parent.subviews().into_iter().find(|child| {
                    child
                        .identifier()
                        .is_some_and(|id| id.to_string().starts_with("dev.prism.clear-glass"))
                });
                if strength == 0 {
                    if let Some(glass) = existing {
                        glass.removeFromSuperview();
                    }
                    return Ok(());
                }
                let glass = if let Some(glass) = existing {
                    glass
                } else {
                    let glass: Retained<NSView> = if AnyClass::get(c"NSGlassEffectView").is_some() {
                        let glass = NSGlassEffectView::initWithFrame(mtm.alloc(), view.frame());
                        glass.setStyle(NSGlassEffectViewStyle::Clear);
                        glass.setTintColor(None);
                        glass.setCornerRadius(18.0);
                        let content = NSView::initWithFrame(mtm.alloc(), glass.bounds());
                        content.setAutoresizingMask(
                            NSAutoresizingMaskOptions::ViewWidthSizable
                                | NSAutoresizingMaskOptions::ViewHeightSizable,
                        );
                        glass.setContentView(Some(&content));
                        Retained::into_super(glass)
                    } else {
                        // Older macOS uses a translucent behind-window material,
                        // never WindowBackground or UnderWindowBackground.
                        let glass = NSVisualEffectView::initWithFrame(mtm.alloc(), view.frame());
                        glass.setMaterial(NSVisualEffectMaterial::Sidebar);
                        glass.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
                        glass.setState(NSVisualEffectState::Active);
                        Retained::into_super(glass)
                    };
                    glass.setIdentifier(Some(&identifier));
                    glass.setAutoresizingMask(
                        NSAutoresizingMaskOptions::ViewWidthSizable
                            | NSAutoresizingMaskOptions::ViewHeightSizable,
                    );
                    // A sibling below the webview keeps foreground text sharp
                    // and leaves its controls and keyboard handling intact.
                    parent.addSubview_positioned_relativeTo(
                        &glass,
                        NSWindowOrderingMode::Below,
                        Some(view),
                    );
                    glass
                };
                glass.setFrame(view.frame());
                glass.setIdentifier(Some(&identifier));
                glass.setAlphaValue(1.0);
                refresh(&glass);
                Ok(())
            })();
            let _ = send.send(result);
        })
        .map_err(|error| error.to_string())?;
    receive
        .await
        .map_err(|_| "Native glass setup was interrupted".to_string())??;
    schedule_refresh(window);
    Ok(())
}

/// Whisp-style screen-space lighting, without a global input monitor or AX access.
pub async fn lighting(window: tauri::WebviewWindow) -> Result<Option<[f64; 2]>, String> {
    if !window.is_visible().unwrap_or(false) {
        return Ok(None);
    }
    let (send, receive) = tokio::sync::oneshot::channel();
    window
        .run_on_main_thread(move || {
            use objc2_app_kit::{NSEvent, NSScreen};
            let result = MainThreadMarker::new().and_then(|mtm| {
                let cursor = NSEvent::mouseLocation();
                let screens = NSScreen::screens(mtm);
                let screen = screens
                    .iter()
                    .find(|screen| {
                        let f = screen.frame();
                        cursor.x >= f.origin.x
                            && cursor.x < f.origin.x + f.size.width
                            && cursor.y >= f.origin.y
                            && cursor.y < f.origin.y + f.size.height
                    })
                    .or_else(|| NSScreen::mainScreen(mtm))?;
                let f = screen.frame();
                if f.size.width <= 0.0 || f.size.height <= 0.0 {
                    return None;
                }
                Some([
                    (cursor.x - f.origin.x) / f.size.width,
                    1.0 - (cursor.y - f.origin.y) / f.size.height,
                ])
            });
            let _ = send.send(result);
        })
        .map_err(|error| error.to_string())?;
    receive
        .await
        .map_err(|_| "Glass lighting was interrupted".to_string())
}
