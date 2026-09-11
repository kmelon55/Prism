use serde::Serialize;
use std::{
    collections::{HashMap, VecDeque},
    sync::{
        atomic::{AtomicI32, AtomicUsize, Ordering},
        Mutex,
    },
};
use tauri::{AppHandle, Manager, State};

const MAX_REMEMBERED_LAYOUTS: usize = 128;

#[cfg(not(target_os = "macos"))]
#[path = "window_management_portable.rs"]
mod portable;

#[derive(Default)]
pub struct WindowManager {
    pub(crate) target_pid: AtomicI32,
    target_window: AtomicUsize,
    previous_layouts: Mutex<PreviousLayouts>,
    cycle: Mutex<Option<CycleStep>>,
}

#[cfg(not(target_os = "macos"))]
impl WindowManager {
    pub(crate) fn target(&self) -> prism_desktop_platform::TargetWindow {
        prism_desktop_platform::TargetWindow {
            id: self.target_window.load(Ordering::Acquire),
            pid: self.target_pid.load(Ordering::Acquire) as u32,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WindowAction {
    MaximizeWidth,
    MaximizeHeight,
    ReasonableSize,
    FirstFourth,
    SecondFourth,
    ThirdFourth,
    LastFourth,
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    NextDisplay,
    PreviousDisplay,

    LeftHalf,
    RightHalf,
    TopHalf,
    BottomHalf,
    TopLeftQuarter,
    TopRightQuarter,
    BottomLeftQuarter,
    BottomRightQuarter,
    TopLeftSixth,
    TopCenterSixth,
    TopRightSixth,
    BottomLeftSixth,
    BottomCenterSixth,
    BottomRightSixth,
    FirstThird,
    CenterThird,
    LastThird,
    LeftTwoThirds,
    CenterTwoThirds,
    RightTwoThirds,
    Maximize,
    AlmostMaximize,
    Center,
    RestorePreviousLayout,
}

impl WindowAction {
    fn parse(raw: &str) -> Result<Self, WindowActionError> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "maximize-width" => Ok(Self::MaximizeWidth),
            "maximize-height" => Ok(Self::MaximizeHeight),
            "reasonable-size" => Ok(Self::ReasonableSize),
            "first-fourth" => Ok(Self::FirstFourth),
            "second-fourth" => Ok(Self::SecondFourth),
            "third-fourth" => Ok(Self::ThirdFourth),
            "last-fourth" => Ok(Self::LastFourth),
            "move-left" => Ok(Self::MoveLeft),
            "move-right" => Ok(Self::MoveRight),
            "move-up" => Ok(Self::MoveUp),
            "move-down" => Ok(Self::MoveDown),
            "next-display" => Ok(Self::NextDisplay),
            "previous-display" => Ok(Self::PreviousDisplay),

            "left-half" | "left_half" | "left" => Ok(Self::LeftHalf),
            "right-half" | "right_half" | "right" => Ok(Self::RightHalf),
            "top-half" => Ok(Self::TopHalf),
            "bottom-half" => Ok(Self::BottomHalf),
            "top-left-quarter" => Ok(Self::TopLeftQuarter),
            "top-right-quarter" => Ok(Self::TopRightQuarter),
            "bottom-left-quarter" => Ok(Self::BottomLeftQuarter),
            "bottom-right-quarter" => Ok(Self::BottomRightQuarter),
            "top-left-sixth" => Ok(Self::TopLeftSixth),
            "top-center-sixth" => Ok(Self::TopCenterSixth),
            "top-right-sixth" => Ok(Self::TopRightSixth),
            "bottom-left-sixth" => Ok(Self::BottomLeftSixth),
            "bottom-center-sixth" => Ok(Self::BottomCenterSixth),
            "bottom-right-sixth" => Ok(Self::BottomRightSixth),
            "first-third" => Ok(Self::FirstThird),
            "center-third" => Ok(Self::CenterThird),
            "last-third" => Ok(Self::LastThird),
            "left-two-thirds" => Ok(Self::LeftTwoThirds),
            "center-two-thirds" => Ok(Self::CenterTwoThirds),
            "right-two-thirds" => Ok(Self::RightTwoThirds),
            "maximize" | "maximise" => Ok(Self::Maximize),
            "almost-maximize" | "almost-maximise" => Ok(Self::AlmostMaximize),
            "center" | "centre" => Ok(Self::Center),
            "restore-previous-layout" | "restore_previous_layout" | "restore" => {
                Ok(Self::RestorePreviousLayout)
            }
            _ => Err(WindowActionError::new(
                "invalidAction",
                "Unknown window layout.",
            )),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::MaximizeWidth => "maximize-width",
            Self::MaximizeHeight => "maximize-height",
            Self::ReasonableSize => "reasonable-size",
            Self::FirstFourth => "first-fourth",
            Self::SecondFourth => "second-fourth",
            Self::ThirdFourth => "third-fourth",
            Self::LastFourth => "last-fourth",
            Self::MoveLeft => "move-left",
            Self::MoveRight => "move-right",
            Self::MoveUp => "move-up",
            Self::MoveDown => "move-down",
            Self::NextDisplay => "next-display",
            Self::PreviousDisplay => "previous-display",

            Self::LeftHalf => "left-half",
            Self::RightHalf => "right-half",
            Self::TopHalf => "top-half",
            Self::BottomHalf => "bottom-half",
            Self::TopLeftQuarter => "top-left-quarter",
            Self::TopRightQuarter => "top-right-quarter",
            Self::BottomLeftQuarter => "bottom-left-quarter",
            Self::BottomRightQuarter => "bottom-right-quarter",
            Self::TopLeftSixth => "top-left-sixth",
            Self::TopCenterSixth => "top-center-sixth",
            Self::TopRightSixth => "top-right-sixth",
            Self::BottomLeftSixth => "bottom-left-sixth",
            Self::BottomCenterSixth => "bottom-center-sixth",
            Self::BottomRightSixth => "bottom-right-sixth",
            Self::FirstThird => "first-third",
            Self::CenterThird => "center-third",
            Self::LastThird => "last-third",
            Self::LeftTwoThirds => "left-two-thirds",
            Self::CenterTwoThirds => "center-two-thirds",
            Self::RightTwoThirds => "right-two-thirds",
            Self::Maximize => "maximize",
            Self::AlmostMaximize => "almost-maximize",
            Self::Center => "center",
            Self::RestorePreviousLayout => "restore-previous-layout",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct WindowIdentity {
    pid: i32,
    accessibility_hash: usize,
}

#[derive(Debug, Default)]
struct PreviousLayouts {
    bounds_by_window: HashMap<WindowIdentity, Rect>,
    insertion_order: VecDeque<WindowIdentity>,
}

impl PreviousLayouts {
    fn remember(&mut self, identity: WindowIdentity, bounds: Rect) -> Option<Rect> {
        let previous = self.bounds_by_window.insert(identity, bounds);
        self.insertion_order
            .retain(|candidate| *candidate != identity);
        self.insertion_order.push_back(identity);

        while self.bounds_by_window.len() > MAX_REMEMBERED_LAYOUTS {
            if let Some(oldest) = self.insertion_order.pop_front() {
                self.bounds_by_window.remove(&oldest);
            }
        }
        previous
    }

    fn rollback_remember(&mut self, identity: WindowIdentity, previous: Option<Rect>) {
        self.bounds_by_window.remove(&identity);
        self.insertion_order
            .retain(|candidate| *candidate != identity);
        if let Some(bounds) = previous {
            self.bounds_by_window.insert(identity, bounds);
            self.insertion_order.push_back(identity);
        }
    }

    fn restore_bounds(&self, identity: WindowIdentity) -> Option<Rect> {
        self.bounds_by_window.get(&identity).copied()
    }

    fn complete_restore(&mut self, identity: WindowIdentity) {
        self.bounds_by_window.remove(&identity);
        self.insertion_order
            .retain(|candidate| *candidate != identity);
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowActionResult {
    action: String,
    supported: bool,
    applied: bool,
    message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityPermissionStatus {
    supported: bool,
    pub(crate) granted: bool,
    can_request: bool,
    message: String,
}

impl AccessibilityPermissionStatus {
    #[cfg(target_os = "macos")]
    fn macos(granted: bool) -> Self {
        Self {
            supported: true,
            granted,
            can_request: !granted,
            message: if granted {
                "Prism can control windows, insert text and detect modifier shortcuts.".to_string()
            } else {
                "Allow Accessibility access for the currently running Prism to control windows, insert text and detect modifier shortcuts.".to_string()
            },
        }
    }

    #[cfg(not(target_os = "macos"))]
    fn unsupported() -> Self {
        Self {
            supported: false,
            granted: false,
            can_request: false,
            message: "Accessibility permission is only used by Prism on macOS.".to_string(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowActionError {
    code: String,
    message: String,
}

impl WindowActionError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[tauri::command]
pub fn get_accessibility_permission_status() -> AccessibilityPermissionStatus {
    #[cfg(target_os = "macos")]
    {
        AccessibilityPermissionStatus::macos(macos::is_accessibility_trusted())
    }

    #[cfg(not(target_os = "macos"))]
    AccessibilityPermissionStatus::unsupported()
}

#[tauri::command]
pub fn request_accessibility_permission() -> AccessibilityPermissionStatus {
    #[cfg(target_os = "macos")]
    {
        AccessibilityPermissionStatus::macos(macos::request_accessibility_trust())
    }

    #[cfg(not(target_os = "macos"))]
    AccessibilityPermissionStatus::unsupported()
}

#[tauri::command]
pub fn open_accessibility_settings() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .spawn()
            .map_err(|error| format!("Prism could not open Accessibility settings: {error}"))?;
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    Err("Accessibility settings are only available on macOS.".to_string())
}

pub(crate) fn paste_target_matches(app: &AppHandle, pid: i32) -> bool {
    #[cfg(target_os = "macos")]
    {
        let manager = app.state::<WindowManager>();
        let expected = manager.target_window.load(Ordering::Acquire);
        expected != 0
            && manager.target_pid.load(Ordering::Acquire) == pid
            && macos::focused_window_hash(pid) == Some(expected)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, pid);
        false
    }
}

pub fn remember_frontmost_app(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    if let Some(manager) = app.try_state::<WindowManager>() {
        let target_pid = macos::frontmost_application_pid()
            .filter(|pid| *pid != std::process::id() as i32)
            .unwrap_or_default();
        manager.target_pid.store(target_pid, Ordering::Release);
        manager.target_window.store(
            macos::focused_window_hash(target_pid).unwrap_or(0),
            Ordering::Release,
        );
    }

    #[cfg(not(target_os = "macos"))]
    if let Some(manager) = app.try_state::<WindowManager>() {
        let target = prism_desktop_platform::foreground().unwrap_or_default();
        manager.target_pid.store(target.pid as i32, Ordering::Release);
        manager.target_window.store(target.id, Ordering::Release);
    }
}

#[tauri::command]
pub fn manage_window(
    app: AppHandle,
    manager: State<'_, WindowManager>,
    action: String,
) -> Result<WindowActionResult, WindowActionError> {
    let action = WindowAction::parse(&action)?;

    #[cfg(target_os = "macos")]
    {
        let pid = manager.target_pid.load(Ordering::Acquire);
        if pid <= 0 {
            return Err(WindowActionError::new(
                "noTargetWindow",
                "Open another application, then show Prism and try the window action again.",
            ));
        }

        macos::apply_window_action(&app, &manager, pid, action)?;
        if let Some(palette) = app.get_webview_window("main") {
            let _ = palette.hide();
        }
        macos::activate_application(pid);
        Ok(WindowActionResult {
            action: action.name().to_string(),
            supported: true,
            applied: true,
            message: if action == WindowAction::RestorePreviousLayout {
                "The target window's previous layout was restored.".to_string()
            } else {
                "The target window was moved.".to_string()
            },
        })
    }

    #[cfg(not(target_os = "macos"))]
    {
        portable::apply(&app, &manager, action)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Clone, Copy)]
struct CycleStep {
    identity: WindowIdentity,
    action: WindowAction,
    index: usize,
    bounds: Rect,
}

fn transfer_rect(current: Rect, source: Rect, destination: Rect) -> Rect {
    let relative_x = ((current.x - source.x) / source.width.max(1.0)).clamp(0.0, 1.0);
    let relative_y = ((current.y - source.y) / source.height.max(1.0)).clamp(0.0, 1.0);
    clamp_rect_to_work_area(
        Rect {
            x: destination.x + relative_x * destination.width,
            y: destination.y + relative_y * destination.height,
            ..current
        },
        destination,
    )
}

fn close_bounds(a: Rect, b: Rect) -> bool {
    (a.x - b.x).abs() <= 2.0
        && (a.y - b.y).abs() <= 2.0
        && (a.width - b.width).abs() <= 2.0
        && (a.height - b.height).abs() <= 2.0
}

// Make room before expanding against a screen edge. Some apps acknowledge AX
// writes but clamp a resize to the space available at the current position.
fn apply_rect_with<E>(
    target: Rect,
    mut read: impl FnMut() -> Result<Rect, E>,
    mut resize: impl FnMut(Rect) -> Result<(), E>,
    mut position: impl FnMut(Rect) -> Result<(), E>,
) -> Result<Rect, E> {
    let mut actual = read()?;
    for _ in 0..2 {
        let staging = Rect {
            x: if target.width > actual.width { actual.x.min(target.x) } else { actual.x },
            y: if target.height > actual.height { actual.y.min(target.y) } else { actual.y },
            ..actual
        };
        if staging.x != actual.x || staging.y != actual.y {
            position(staging)?;
        }
        resize(target)?;
        position(target)?;
        actual = read()?;
        if close_bounds(actual, target) { break; }
    }
    Ok(actual)
}

fn cycle_index(
    previous: Option<CycleStep>,
    identity: WindowIdentity,
    action: WindowAction,
    current: Rect,
    enabled: bool,
) -> usize {
    if !enabled || !matches!(action, WindowAction::LeftHalf | WindowAction::RightHalf) {
        return 0;
    }
    previous
        .filter(|step| {
            step.identity == identity && step.action == action && close_bounds(step.bounds, current)
        })
        .map_or(0, |step| (step.index + 1) % 3)
}

fn configured_rect(
    action: WindowAction,
    work: Rect,
    current: Rect,
    options: &crate::window_preferences::WindowOptions,
    index: usize,
) -> Rect {
    let edge = f64::from(options.edge_gap).min(work.width.min(work.height) / 4.0);
    let area = Rect {
        x: work.x + edge,
        y: work.y + edge,
        width: work.width - 2.0 * edge,
        height: work.height - 2.0 * edge,
    };
    let mapped = match (action, index, options.reverse_cycle) {
        (WindowAction::LeftHalf, 1, false) | (WindowAction::LeftHalf, 2, true) => {
            WindowAction::FirstThird
        }
        (WindowAction::LeftHalf, 2, false) | (WindowAction::LeftHalf, 1, true) => {
            WindowAction::LeftTwoThirds
        }
        (WindowAction::RightHalf, 1, false) | (WindowAction::RightHalf, 2, true) => {
            WindowAction::LastThird
        }
        (WindowAction::RightHalf, 2, false) | (WindowAction::RightHalf, 1, true) => {
            WindowAction::RightTwoThirds
        }
        _ => action,
    };
    if action == WindowAction::AlmostMaximize {
        let fraction = f64::from(options.almost_maximize) / 100.0;
        return Rect {
            x: area.x + area.width * (1.0 - fraction) / 2.0,
            y: area.y + area.height * (1.0 - fraction) / 2.0,
            width: area.width * fraction,
            height: area.height * fraction,
        };
    }
    let mut rect = target_rect(mapped, area, current);
    if !matches!(
        action,
        WindowAction::Center
            | WindowAction::Maximize
            | WindowAction::RestorePreviousLayout
            | WindowAction::MaximizeWidth
            | WindowAction::MaximizeHeight
            | WindowAction::ReasonableSize
            | WindowAction::MoveLeft
            | WindowAction::MoveRight
            | WindowAction::MoveUp
            | WindowAction::MoveDown
            | WindowAction::NextDisplay
            | WindowAction::PreviousDisplay
    ) {
        let inset = f64::from(options.gap).min(rect.width.min(rect.height) / 2.0) / 2.0;
        let right = rect.x + rect.width;
        let bottom = rect.y + rect.height;
        if rect.x > area.x + 1.0 {
            rect.x += inset;
            rect.width -= inset;
        }
        if right < area.x + area.width - 1.0 {
            rect.width -= inset;
        }
        if rect.y > area.y + 1.0 {
            rect.y += inset;
            rect.height -= inset;
        }
        if bottom < area.y + area.height - 1.0 {
            rect.height -= inset;
        }
    }
    rect
}

fn clamp_rect_to_work_area(bounds: Rect, work_area: Rect) -> Rect {
    if ![
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        work_area.x,
        work_area.y,
        work_area.width,
        work_area.height,
    ]
    .into_iter()
    .all(f64::is_finite)
        || work_area.width <= 0.0
        || work_area.height <= 0.0
    {
        return work_area;
    }

    let width = bounds.width.max(1.0).min(work_area.width);
    let height = bounds.height.max(1.0).min(work_area.height);
    Rect {
        x: bounds
            .x
            .clamp(work_area.x, work_area.x + work_area.width - width),
        y: bounds
            .y
            .clamp(work_area.y, work_area.y + work_area.height - height),
        width,
        height,
    }
}

fn target_rect(action: WindowAction, work_area: Rect, current: Rect) -> Rect {
    let half_width = work_area.width / 2.0;
    let half_height = work_area.height / 2.0;
    let third_width = work_area.width / 3.0;
    match action {
        WindowAction::MaximizeWidth => Rect {
            x: work_area.x,
            width: work_area.width,
            ..clamp_rect_to_work_area(current, work_area)
        },
        WindowAction::MaximizeHeight => Rect {
            y: work_area.y,
            height: work_area.height,
            ..clamp_rect_to_work_area(current, work_area)
        },
        WindowAction::ReasonableSize => {
            let width = (work_area.width * 0.6).min(1025.0);
            let height = (work_area.height * 0.6).min(900.0);
            Rect {
                x: work_area.x + (work_area.width - width) / 2.0,
                y: work_area.y + (work_area.height - height) / 2.0,
                width,
                height,
            }
        }
        WindowAction::FirstFourth
        | WindowAction::SecondFourth
        | WindowAction::ThirdFourth
        | WindowAction::LastFourth => {
            let index = match action {
                WindowAction::SecondFourth => 1.0,
                WindowAction::ThirdFourth => 2.0,
                WindowAction::LastFourth => 3.0,
                _ => 0.0,
            };
            Rect {
                x: work_area.x + work_area.width * index / 4.0,
                width: work_area.width / 4.0,
                ..work_area
            }
        }
        WindowAction::MoveLeft => Rect {
            x: work_area.x,
            ..clamp_rect_to_work_area(current, work_area)
        },
        WindowAction::MoveRight => {
            let rect = clamp_rect_to_work_area(current, work_area);
            Rect {
                x: work_area.x + work_area.width - rect.width,
                ..rect
            }
        }
        WindowAction::MoveUp => Rect {
            y: work_area.y,
            ..clamp_rect_to_work_area(current, work_area)
        },
        WindowAction::MoveDown => {
            let rect = clamp_rect_to_work_area(current, work_area);
            Rect {
                y: work_area.y + work_area.height - rect.height,
                ..rect
            }
        }
        WindowAction::NextDisplay | WindowAction::PreviousDisplay => {
            clamp_rect_to_work_area(current, work_area)
        }
        WindowAction::LeftHalf => Rect {
            width: half_width,
            ..work_area
        },
        WindowAction::RightHalf => Rect {
            x: work_area.x + half_width,
            width: half_width,
            ..work_area
        },
        WindowAction::TopHalf => Rect {
            height: half_height,
            ..work_area
        },
        WindowAction::BottomHalf => Rect {
            y: work_area.y + half_height,
            height: half_height,
            ..work_area
        },
        WindowAction::TopLeftQuarter => Rect {
            width: half_width,
            height: half_height,
            ..work_area
        },
        WindowAction::TopRightQuarter => Rect {
            x: work_area.x + half_width,
            width: half_width,
            height: half_height,
            ..work_area
        },
        WindowAction::BottomLeftQuarter => Rect {
            y: work_area.y + half_height,
            width: half_width,
            height: half_height,
            ..work_area
        },
        WindowAction::BottomRightQuarter => Rect {
            x: work_area.x + half_width,
            y: work_area.y + half_height,
            width: half_width,
            height: half_height,
        },
        WindowAction::TopLeftSixth => Rect {
            width: third_width,
            height: half_height,
            ..work_area
        },
        WindowAction::TopCenterSixth => Rect {
            x: work_area.x + third_width,
            width: third_width,
            height: half_height,
            ..work_area
        },
        WindowAction::TopRightSixth => Rect {
            x: work_area.x + third_width * 2.0,
            width: third_width,
            height: half_height,
            ..work_area
        },
        WindowAction::BottomLeftSixth => Rect {
            y: work_area.y + half_height,
            width: third_width,
            height: half_height,
            ..work_area
        },
        WindowAction::BottomCenterSixth => Rect {
            x: work_area.x + third_width,
            y: work_area.y + half_height,
            width: third_width,
            height: half_height,
        },
        WindowAction::BottomRightSixth => Rect {
            x: work_area.x + third_width * 2.0,
            y: work_area.y + half_height,
            width: third_width,
            height: half_height,
        },
        WindowAction::FirstThird => Rect {
            width: third_width,
            ..work_area
        },
        WindowAction::CenterThird => Rect {
            x: work_area.x + third_width,
            width: third_width,
            ..work_area
        },
        WindowAction::LastThird => Rect {
            x: work_area.x + third_width * 2.0,
            width: third_width,
            ..work_area
        },
        WindowAction::LeftTwoThirds => Rect {
            width: third_width * 2.0,
            ..work_area
        },
        WindowAction::CenterTwoThirds => Rect {
            x: work_area.x + third_width / 2.0,
            width: third_width * 2.0,
            ..work_area
        },
        WindowAction::RightTwoThirds => Rect {
            x: work_area.x + third_width,
            width: third_width * 2.0,
            ..work_area
        },
        WindowAction::Maximize => work_area,
        WindowAction::AlmostMaximize => {
            let horizontal_margin = work_area.width * 0.05;
            let vertical_margin = work_area.height * 0.05;
            Rect {
                x: work_area.x + horizontal_margin,
                y: work_area.y + vertical_margin,
                width: work_area.width - horizontal_margin * 2.0,
                height: work_area.height - vertical_margin * 2.0,
            }
        }
        WindowAction::Center => Rect {
            x: work_area.x + ((work_area.width - current.width) / 2.0).max(0.0),
            y: work_area.y + ((work_area.height - current.height) / 2.0).max(0.0),
            width: current.width.min(work_area.width),
            height: current.height.min(work_area.height),
        },
        WindowAction::RestorePreviousLayout => {
            unreachable!("restore geometry comes from the in-memory window history")
        }
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{Rect, WindowAction, WindowActionError, WindowIdentity, WindowManager};
    use accessibility_sys::{
        error_string, kAXErrorSuccess, kAXFocusedWindowAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXTrustedCheckOptionPrompt, kAXValueTypeCGPoint, kAXValueTypeCGSize,
        AXIsProcessTrusted, AXIsProcessTrustedWithOptions, AXUIElementCopyAttributeValue,
        AXUIElementCreateApplication, AXUIElementRef, AXUIElementSetAttributeValue, AXValueCreate,
        AXValueGetValue, AXValueRef,
    };
    use core_foundation::{
        base::TCFType, boolean::CFBoolean, dictionary::CFDictionary, string::CFString,
    };
    use core_foundation_sys::base::{CFHash, CFRelease, CFTypeRef};
    use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication, NSWorkspace};
    use std::{ffi::c_void, ptr};
    use tauri::AppHandle;

    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    struct CGPoint {
        x: f64,
        y: f64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    struct CGSize {
        width: f64,
        height: f64,
    }

    struct OwnedCf(CFTypeRef);

    impl Drop for OwnedCf {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CFRelease(self.0) };
            }
        }
    }

    pub fn focused_window_hash(pid: i32) -> Option<usize> {
        if pid <= 0 || !is_accessibility_trusted() {
            return None;
        }
        let application = unsafe { AXUIElementCreateApplication(pid) };
        if application.is_null() {
            return None;
        }
        let _guard = OwnedCf(application.cast());
        let window = copy_attribute(application, kAXFocusedWindowAttribute).ok()?;
        Some(unsafe { CFHash(window.0) })
    }

    pub fn frontmost_application_pid() -> Option<i32> {
        NSWorkspace::sharedWorkspace()
            .frontmostApplication()
            .map(|application| application.processIdentifier())
            .filter(|pid| *pid > 0)
    }

    pub fn is_accessibility_trusted() -> bool {
        unsafe { AXIsProcessTrusted() }
    }

    pub fn request_accessibility_trust() -> bool {
        let prompt_key = unsafe { CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt) };
        let prompt_value = CFBoolean::true_value();
        let options = CFDictionary::from_CFType_pairs(&[(prompt_key, prompt_value)]);
        unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef()) }
    }

    pub fn activate_application(pid: i32) {
        if let Some(application) =
            NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
        {
            let _ = application.activateWithOptions(NSApplicationActivationOptions::empty());
        }
    }

    pub fn apply_window_action(
        app: &AppHandle,
        manager: &WindowManager,
        pid: i32,
        action: WindowAction,
    ) -> Result<(), WindowActionError> {
        if !is_accessibility_trusted() {
            return Err(WindowActionError::new(
                "accessibilityPermissionRequired",
                "Allow Prism in System Settings > Privacy & Security > Accessibility, then try again.",
            ));
        }

        let application = unsafe { AXUIElementCreateApplication(pid) };
        if application.is_null() {
            return Err(WindowActionError::new(
                "targetUnavailable",
                "The application owning the target window is no longer available.",
            ));
        }
        let _application_guard = OwnedCf(application.cast());
        let window_value = copy_attribute(application, kAXFocusedWindowAttribute)?;
        let window = window_value.0 as AXUIElementRef;

        let position = read_point(window)?;
        let size = read_size(window)?;
        let current = Rect {
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height,
        };
        let identity = WindowIdentity {
            pid,
            // AXUIElement is a CFType; equal references to the same accessibility
            // element have the same hash even when fetched by separate commands.
            accessibility_hash: unsafe { CFHash(window.cast()) },
        };

        if action == WindowAction::RestorePreviousLayout {
            let mut previous_layouts = manager
                .previous_layouts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let previous = previous_layouts.restore_bounds(identity).ok_or_else(|| {
                WindowActionError::new(
                    "noPreviousWindowLayout",
                    "There is no previous Prism window layout to restore for the focused window.",
                )
            })?;
            let previous_center_x = previous.x + previous.width / 2.0;
            let previous_center_y = previous.y + previous.height / 2.0;
            let current_center_x = current.x + current.width / 2.0;
            let current_center_y = current.y + current.height / 2.0;
            let monitor = app
                .monitor_from_point(previous_center_x, previous_center_y)
                .ok()
                .flatten()
                .or_else(|| {
                    app.monitor_from_point(current_center_x, current_center_y)
                        .ok()
                        .flatten()
                })
                .or_else(|| app.primary_monitor().ok().flatten())
                .ok_or_else(|| {
                    WindowActionError::new(
                        "monitorUnavailable",
                        "Prism could not identify a monitor for the previous window layout.",
                    )
                })?;
            let scale = monitor.scale_factor();
            let work = monitor.work_area();
            let work_area = Rect {
                x: f64::from(work.position.x) / scale,
                y: f64::from(work.position.y) / scale,
                width: f64::from(work.size.width) / scale,
                height: f64::from(work.size.height) / scale,
            };
            set_rect(window, super::clamp_rect_to_work_area(previous, work_area))?;
            previous_layouts.complete_restore(identity);
            drop(previous_layouts);
            *manager
                .cycle
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
            return Ok(());
        }

        let center_x = current.x + current.width / 2.0;
        let center_y = current.y + current.height / 2.0;
        let monitor = app
            .monitor_from_point(center_x, center_y)
            .map_err(|error| {
                WindowActionError::new(
                    "monitorUnavailable",
                    format!("Prism could not inspect the target monitor: {error}"),
                )
            })?
            .or_else(|| app.primary_monitor().ok().flatten())
            .ok_or_else(|| {
                WindowActionError::new(
                    "monitorUnavailable",
                    "Prism could not identify a monitor for the target window.",
                )
            })?;
        let scale = monitor.scale_factor();
        let work = monitor.work_area();
        let work_area = Rect {
            x: f64::from(work.position.x) / scale,
            y: f64::from(work.position.y) / scale,
            width: f64::from(work.size.width) / scale,
            height: f64::from(work.size.height) / scale,
        };
        let options = crate::window_preferences::load(app)
            .map_err(|message| WindowActionError::new("invalidWindowOptions", message))?;
        let mut cycle = manager
            .cycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let index = super::cycle_index(*cycle, identity, action, current, options.cycle);
        let continuing = options.cycle
            && cycle.is_some_and(|step| {
                step.identity == identity
                    && step.action == action
                    && super::close_bounds(step.bounds, current)
            });
        let target = if matches!(
            action,
            WindowAction::NextDisplay | WindowAction::PreviousDisplay
        ) {
            let mut monitors = app.available_monitors().map_err(|_| {
                WindowActionError::new("monitorUnavailable", "Could not inspect displays.")
            })?;
            monitors.sort_by_key(|monitor| (monitor.position().x, monitor.position().y));
            let source = monitors
                .iter()
                .position(|candidate| candidate.position() == monitor.position())
                .unwrap_or(0);
            if monitors.len() < 2 {
                return Err(WindowActionError::new(
                    "noOtherDisplay",
                    "Connect another display to move this window.",
                ));
            }
            let destination = if action == WindowAction::NextDisplay {
                (source + 1) % monitors.len()
            } else {
                (source + monitors.len() - 1) % monitors.len()
            };
            let monitor = &monitors[destination];
            let scale = monitor.scale_factor();
            let work = monitor.work_area();
            let destination = Rect {
                x: f64::from(work.position.x) / scale,
                y: f64::from(work.position.y) / scale,
                width: f64::from(work.size.width) / scale,
                height: f64::from(work.size.height) / scale,
            };
            super::transfer_rect(current, work_area, destination)
        } else {
            super::configured_rect(action, work_area, current, &options, index)
        };

        let mut previous_layouts = manager
            .previous_layouts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let replaced = if continuing {
            None
        } else {
            Some(previous_layouts.remember(identity, current))
        };
        let applied = match set_rect(window, target) {
            Ok(bounds) => bounds,
            Err(error) => {
            // A size failure may follow a position change. Restore geometry as well as history.
            if set_rect(window, current).is_ok() {
                if let Some(previous) = replaced {
                    previous_layouts.rollback_remember(identity, previous);
                }
            }
            *cycle = None;
            return Err(error);
            }
        };
        *cycle = if options.cycle
            && matches!(action, WindowAction::LeftHalf | WindowAction::RightHalf)
        {
            Some(super::CycleStep {
                identity,
                action,
                index,
                bounds: applied,
            })
        } else {
            None
        };
        Ok(())
    }

    fn set_rect(window: AXUIElementRef, bounds: Rect) -> Result<Rect, WindowActionError> {
        super::apply_rect_with(
            bounds,
            || {
                let position = read_point(window)?;
                let size = read_size(window)?;
                Ok(Rect { x: position.x, y: position.y, width: size.width, height: size.height })
            },
            |rect| set_size(window, CGSize { width: rect.width, height: rect.height }),
            |rect| set_point(window, CGPoint { x: rect.x, y: rect.y }),
        )
    }

    fn copy_attribute(
        element: AXUIElementRef,
        attribute_name: &str,
    ) -> Result<OwnedCf, WindowActionError> {
        let attribute = CFString::new(attribute_name);
        let mut value: CFTypeRef = ptr::null();
        let status = unsafe {
            AXUIElementCopyAttributeValue(element, attribute.as_concrete_TypeRef(), &mut value)
        };
        if status != kAXErrorSuccess || value.is_null() {
            return Err(ax_error(
                "windowUnavailable",
                "Prism could not read the focused window",
                status,
            ));
        }
        Ok(OwnedCf(value))
    }

    fn read_point(window: AXUIElementRef) -> Result<CGPoint, WindowActionError> {
        let value = copy_attribute(window, kAXPositionAttribute)?;
        let mut point = CGPoint::default();
        let success = unsafe {
            AXValueGetValue(
                value.0 as AXValueRef,
                kAXValueTypeCGPoint,
                (&mut point as *mut CGPoint).cast::<c_void>(),
            )
        };
        if !success {
            return Err(WindowActionError::new(
                "windowUnavailable",
                "Prism could not read the target window position.",
            ));
        }
        Ok(point)
    }

    fn read_size(window: AXUIElementRef) -> Result<CGSize, WindowActionError> {
        let value = copy_attribute(window, kAXSizeAttribute)?;
        let mut size = CGSize::default();
        let success = unsafe {
            AXValueGetValue(
                value.0 as AXValueRef,
                kAXValueTypeCGSize,
                (&mut size as *mut CGSize).cast::<c_void>(),
            )
        };
        if !success {
            return Err(WindowActionError::new(
                "windowUnavailable",
                "Prism could not read the target window size.",
            ));
        }
        Ok(size)
    }

    fn set_point(window: AXUIElementRef, point: CGPoint) -> Result<(), WindowActionError> {
        set_attribute_value(
            window,
            kAXPositionAttribute,
            kAXValueTypeCGPoint,
            (&point as *const CGPoint).cast::<c_void>(),
        )
    }

    fn set_size(window: AXUIElementRef, size: CGSize) -> Result<(), WindowActionError> {
        set_attribute_value(
            window,
            kAXSizeAttribute,
            kAXValueTypeCGSize,
            (&size as *const CGSize).cast::<c_void>(),
        )
    }

    fn set_attribute_value(
        window: AXUIElementRef,
        attribute_name: &str,
        value_type: u32,
        value_pointer: *const c_void,
    ) -> Result<(), WindowActionError> {
        let attribute = CFString::new(attribute_name);
        let value: AXValueRef = unsafe { AXValueCreate(value_type, value_pointer) };
        if value.is_null() {
            return Err(WindowActionError::new(
                "windowActionFailed",
                "Prism could not prepare the requested window geometry.",
            ));
        }
        let _value_guard = OwnedCf(value.cast());
        let status = unsafe {
            AXUIElementSetAttributeValue(window, attribute.as_concrete_TypeRef(), value.cast())
        };
        if status != kAXErrorSuccess {
            return Err(ax_error(
                "windowActionFailed",
                "The target application refused the requested window geometry",
                status,
            ));
        }
        Ok(())
    }

    fn ax_error(code: &str, context: &str, status: i32) -> WindowActionError {
        WindowActionError::new(
            code,
            format!(
                "{context} ({}). Confirm that the window is resizable and that Prism remains enabled in System Settings > Privacy & Security > Accessibility.",
                error_string(status)
            ),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn right_half_cycles_stay_on_the_right_when_the_app_clamps_growth_at_screen_edges() {
        use std::cell::Cell;
        for origin in [0.0, -1200.0] {
            for reverse in [false, true] {
                let work = Rect { x: origin, y: 30.0, width: 1200.0, height: 900.0 };
                let identity = WindowIdentity { pid: 1, accessibility_hash: 1 };
                let options = crate::window_preferences::WindowOptions {
                    reverse_cycle: reverse, ..Default::default()
                };
                let frame = Cell::new(Rect { x: origin + 100.0, y: 80.0, width: 500.0, height: 500.0 });
                let mut previous = None;
                let widths = if reverse { [600.0, 800.0, 400.0] } else { [600.0, 400.0, 800.0] };
                for step in 0..12 {
                    let index = cycle_index(previous, identity, WindowAction::RightHalf, frame.get(), true);
                    let target = configured_rect(WindowAction::RightHalf, work, frame.get(), &options, index);
                    let actual = apply_rect_with::<()>(target,
                        || Ok(frame.get()),
                        |rect| {
                            let current = frame.get();
                            frame.set(Rect {
                                width: rect.width.min(work.x + work.width - current.x),
                                height: rect.height.min(work.y + work.height - current.y),
                                ..current
                            });
                            Ok(())
                        },
                        |rect| {
                            let current = frame.get();
                            frame.set(Rect {
                                x: rect.x.min(work.x + work.width - current.width),
                                y: rect.y.min(work.y + work.height - current.height),
                                ..current
                            });
                            Ok(())
                        },
                    ).unwrap();
                    assert_eq!(actual.width, widths[step % 3], "step {step}, reverse {reverse}");
                    assert_eq!(actual.x + actual.width, work.x + work.width);
                    assert_eq!(actual.y, work.y);
                    assert_eq!(actual.height, work.height);
                    previous = Some(CycleStep { identity, action: WindowAction::RightHalf, index, bounds: actual });
                }
            }
        }
    }

    #[test]
    fn frame_application_keeps_actual_app_constraints_and_bounds_retries() {
        use std::cell::Cell;
        let constrained = Rect { x: 0.0, y: 0.0, width: 600.0, height: 600.0 };
        let writes = Cell::new(0);
        let actual = apply_rect_with::<()>(Rect { width: 400.0, ..constrained },
            || Ok(constrained),
            |_| { writes.set(writes.get() + 1); Ok(()) },
            |_| Ok(()),
        ).unwrap();
        assert_eq!(actual, constrained);
        assert_eq!(writes.get(), 2);
    }

    #[test]
    fn repeated_half_cycles_and_resets_for_other_windows_actions_and_manual_moves() {
        let work = Rect {
            x: -1200.0,
            y: 30.0,
            width: 1200.0,
            height: 900.0,
        };
        let identity = WindowIdentity {
            pid: 1,
            accessibility_hash: 1,
        };
        let options = crate::window_preferences::WindowOptions::default();
        let mut previous = None;
        let mut current = Rect {
            x: -1000.0,
            y: 100.0,
            width: 500.0,
            height: 400.0,
        };
        for expected in [600.0, 400.0, 800.0, 600.0] {
            let index = cycle_index(previous, identity, WindowAction::LeftHalf, current, true);
            current = configured_rect(WindowAction::LeftHalf, work, current, &options, index);
            assert_eq!(current.width, expected);
            assert_eq!(current.x, work.x);
            previous = Some(CycleStep {
                identity,
                action: WindowAction::LeftHalf,
                index,
                bounds: current,
            });
        }
        assert_eq!(
            cycle_index(
                previous,
                WindowIdentity { pid: 2, ..identity },
                WindowAction::LeftHalf,
                current,
                true
            ),
            0
        );
        assert_eq!(
            cycle_index(previous, identity, WindowAction::RightHalf, current, true),
            0
        );
        assert_eq!(
            cycle_index(
                previous,
                identity,
                WindowAction::LeftHalf,
                Rect {
                    x: current.x + 10.0,
                    ..current
                },
                true
            ),
            0
        );
        assert_eq!(
            cycle_index(previous, identity, WindowAction::LeftHalf, current, false),
            0
        );
    }

    #[test]
    fn configured_gaps_are_shared_and_reverse_cycle_changes_order() {
        let work = Rect {
            x: 0.0,
            y: 25.0,
            width: 1200.0,
            height: 900.0,
        };
        let options = crate::window_preferences::WindowOptions {
            gap: 12,
            edge_gap: 20,
            reverse_cycle: true,
            ..Default::default()
        };
        let left = configured_rect(WindowAction::LeftHalf, work, Rect::default(), &options, 0);
        let right = configured_rect(WindowAction::RightHalf, work, Rect::default(), &options, 0);
        assert_eq!(left.x, 20.0);
        assert_eq!(left.y, 45.0);
        assert_eq!(right.x - left.x - left.width, 12.0);
        assert_eq!(right.x + right.width, 1180.0);
        let large = configured_rect(WindowAction::RightHalf, work, Rect::default(), &options, 1);
        let small = configured_rect(WindowAction::RightHalf, work, Rect::default(), &options, 2);
        assert!(large.width > right.width && right.width > small.width);
        assert!((large.x + large.width - 1180.0).abs() < 0.01);
    }

    #[test]
    fn size_edge_and_display_commands_preserve_unaffected_geometry() {
        let work = Rect {
            x: 0.0,
            y: 25.0,
            width: 1200.0,
            height: 900.0,
        };
        let current = Rect {
            x: 100.0,
            y: 80.0,
            width: 400.0,
            height: 500.0,
        };
        assert_eq!(
            target_rect(WindowAction::MaximizeWidth, work, current),
            Rect {
                x: 0.0,
                width: 1200.0,
                ..current
            }
        );
        assert_eq!(
            target_rect(WindowAction::MoveRight, work, current),
            Rect {
                x: 800.0,
                ..current
            }
        );
        assert_eq!(
            target_rect(WindowAction::LastFourth, work, current),
            Rect {
                x: 900.0,
                width: 300.0,
                ..work
            }
        );
        let destination = Rect {
            x: -800.0,
            y: 0.0,
            width: 800.0,
            height: 600.0,
        };
        let moved = transfer_rect(current, work, destination);
        assert_eq!(moved.width, current.width);
        assert_eq!(moved.height, current.height);
        assert!(moved.x >= -800.0 && moved.x + moved.width <= 0.0);
        assert!(moved.y >= 0.0 && moved.y + moved.height <= 600.0);
    }

    #[test]
    fn action_parser_accepts_frontend_friendly_aliases() {
        assert_eq!(
            WindowAction::parse("left-half").unwrap(),
            WindowAction::LeftHalf
        );
        assert_eq!(
            WindowAction::parse("right_half").unwrap(),
            WindowAction::RightHalf
        );
        assert_eq!(
            WindowAction::parse("maximise").unwrap(),
            WindowAction::Maximize
        );
        assert_eq!(
            WindowAction::parse("restore").unwrap(),
            WindowAction::RestorePreviousLayout
        );
        assert_eq!(
            WindowAction::parse("restore_previous_layout")
                .unwrap()
                .name(),
            "restore-previous-layout"
        );
        assert!(WindowAction::parse("tile-thirds").is_err());
    }

    #[test]
    fn previous_layouts_are_window_specific_and_consumed_once() {
        let first_window = WindowIdentity {
            pid: 10,
            accessibility_hash: 100,
        };
        let second_window = WindowIdentity {
            pid: 10,
            accessibility_hash: 200,
        };
        let first_bounds = Rect {
            x: 10.0,
            y: 20.0,
            width: 300.0,
            height: 400.0,
        };
        let second_bounds = Rect {
            x: 50.0,
            y: 60.0,
            width: 700.0,
            height: 800.0,
        };
        let mut layouts = PreviousLayouts::default();

        layouts.remember(first_window, first_bounds);
        layouts.remember(second_window, second_bounds);

        assert_eq!(layouts.restore_bounds(first_window), Some(first_bounds));
        assert_eq!(layouts.restore_bounds(second_window), Some(second_bounds));
        layouts.complete_restore(first_window);
        assert_eq!(layouts.restore_bounds(first_window), None);
        assert_eq!(layouts.restore_bounds(second_window), Some(second_bounds));
    }

    #[test]
    fn failed_layout_before_geometry_change_preserves_the_earlier_checkpoint() {
        let identity = WindowIdentity {
            pid: 42,
            accessibility_hash: 9001,
        };
        let original = Rect {
            x: 1.0,
            y: 2.0,
            width: 3.0,
            height: 4.0,
        };
        let current = Rect {
            x: 10.0,
            y: 20.0,
            width: 30.0,
            height: 40.0,
        };
        let mut layouts = PreviousLayouts::default();
        layouts.remember(identity, original);

        let replaced = layouts.remember(identity, current);
        layouts.rollback_remember(identity, replaced);

        assert_eq!(layouts.restore_bounds(identity), Some(original));
    }

    #[test]
    fn stale_layout_history_is_bounded() {
        let mut layouts = PreviousLayouts::default();

        for token in 0..=MAX_REMEMBERED_LAYOUTS {
            layouts.remember(
                WindowIdentity {
                    pid: 99,
                    accessibility_hash: token,
                },
                Rect {
                    x: token as f64,
                    ..Rect::default()
                },
            );
        }

        assert_eq!(layouts.bounds_by_window.len(), MAX_REMEMBERED_LAYOUTS);
        assert_eq!(
            layouts.restore_bounds(WindowIdentity {
                pid: 99,
                accessibility_hash: 0,
            }),
            None
        );
        assert!(layouts
            .restore_bounds(WindowIdentity {
                pid: 99,
                accessibility_hash: MAX_REMEMBERED_LAYOUTS,
            })
            .is_some());
    }

    #[test]
    fn half_and_maximize_actions_use_the_monitor_work_area() {
        let work = Rect {
            x: 20.0,
            y: 40.0,
            width: 1200.0,
            height: 800.0,
        };
        let current = Rect {
            width: 500.0,
            height: 400.0,
            ..Rect::default()
        };

        assert_eq!(
            target_rect(WindowAction::LeftHalf, work, current),
            Rect {
                x: 20.0,
                y: 40.0,
                width: 600.0,
                height: 800.0,
            }
        );
        assert_eq!(target_rect(WindowAction::Maximize, work, current), work);
        assert_eq!(target_rect(WindowAction::RightHalf, work, current).x, 620.0);
    }

    #[test]
    fn center_preserves_size_until_the_window_exceeds_the_work_area() {
        let work = Rect {
            x: 0.0,
            y: 20.0,
            width: 1000.0,
            height: 700.0,
        };
        let current = Rect {
            width: 600.0,
            height: 400.0,
            ..Rect::default()
        };
        assert_eq!(
            target_rect(WindowAction::Center, work, current),
            Rect {
                x: 200.0,
                y: 170.0,
                width: 600.0,
                height: 400.0,
            }
        );
    }

    #[test]
    fn quarter_and_third_layouts_use_predictable_screen_fractions() {
        let work = Rect {
            x: 30.0,
            y: 20.0,
            width: 1200.0,
            height: 900.0,
        };
        let current = Rect::default();

        assert_eq!(
            target_rect(WindowAction::BottomRightQuarter, work, current),
            Rect {
                x: 630.0,
                y: 470.0,
                width: 600.0,
                height: 450.0,
            }
        );
        assert_eq!(
            target_rect(WindowAction::CenterThird, work, current),
            Rect {
                x: 430.0,
                y: 20.0,
                width: 400.0,
                height: 900.0,
            }
        );
        assert_eq!(
            target_rect(WindowAction::RightTwoThirds, work, current),
            Rect {
                x: 430.0,
                y: 20.0,
                width: 800.0,
                height: 900.0,
            }
        );
        assert_eq!(
            target_rect(WindowAction::BottomCenterSixth, work, current),
            Rect {
                x: 430.0,
                y: 470.0,
                width: 400.0,
                height: 450.0,
            }
        );
    }

    #[test]
    fn almost_maximize_keeps_a_five_percent_margin() {
        let work = Rect {
            x: 0.0,
            y: 20.0,
            width: 1000.0,
            height: 800.0,
        };

        assert_eq!(
            target_rect(WindowAction::AlmostMaximize, work, Rect::default()),
            Rect {
                x: 50.0,
                y: 60.0,
                width: 900.0,
                height: 720.0,
            }
        );
    }

    #[test]
    fn restored_layout_is_clamped_after_monitor_changes() {
        let work = Rect {
            x: 0.0,
            y: 20.0,
            width: 1000.0,
            height: 700.0,
        };

        assert_eq!(
            clamp_rect_to_work_area(
                Rect {
                    x: 1800.0,
                    y: -200.0,
                    width: 1400.0,
                    height: 900.0,
                },
                work,
            ),
            work,
        );
        assert_eq!(
            clamp_rect_to_work_area(
                Rect {
                    x: 900.0,
                    y: 600.0,
                    width: 300.0,
                    height: 200.0,
                },
                work,
            ),
            Rect {
                x: 700.0,
                y: 520.0,
                width: 300.0,
                height: 200.0,
            },
        );
    }
}
