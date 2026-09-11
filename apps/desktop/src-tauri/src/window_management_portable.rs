use super::*;
use prism_desktop_platform as platform;

impl From<platform::Bounds> for Rect {
    fn from(b: platform::Bounds) -> Self {
        Self {
            x: b.x,
            y: b.y,
            width: b.width,
            height: b.height,
        }
    }
}
impl From<Rect> for platform::Bounds {
    fn from(b: Rect) -> Self {
        Self {
            x: b.x,
            y: b.y,
            width: b.width,
            height: b.height,
        }
    }
}
fn error(message: String) -> WindowActionError {
    WindowActionError::new("windowActionFailed", message)
}
fn monitor_for(areas: &[Rect], bounds: Rect) -> usize {
    // Largest intersection remains stable for windows straddling monitors and negative origins.
    areas
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| {
            let overlap = |area: &Rect| {
                ((bounds.x + bounds.width).min(area.x + area.width) - bounds.x.max(area.x)).max(0.0)
                    * ((bounds.y + bounds.height).min(area.y + area.height) - bounds.y.max(area.y))
                        .max(0.0)
            };
            overlap(a).total_cmp(&overlap(b))
        })
        .map(|(index, _)| index)
        .unwrap_or(0)
}
pub(super) fn apply(
    app: &AppHandle,
    manager: &WindowManager,
    action: WindowAction,
) -> Result<WindowActionResult, WindowActionError> {
    let target = manager.target();
    let current = Rect::from(platform::bounds(target).map_err(error)?);
    let identity = WindowIdentity {
        pid: target.pid as i32,
        accessibility_hash: target.id,
    };
    let mut areas: Vec<Rect> = platform::work_areas()
        .map_err(error)?
        .into_iter()
        .map(Rect::from)
        .collect();
    areas.sort_by(|a, b| a.x.total_cmp(&b.x).then(a.y.total_cmp(&b.y)));
    if areas.is_empty() {
        return Err(error("No monitor is available.".into()));
    }
    let source = monitor_for(&areas, current);
    let options = crate::window_preferences::load(app).map_err(error)?;
    let mut cycle = manager
        .cycle
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut previous = manager
        .previous_layouts
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let index = cycle_index(*cycle, identity, action, current, options.cycle);
    let restoring = action == WindowAction::RestorePreviousLayout;
    let desired = if restoring {
        let remembered = previous
            .restore_bounds(identity)
            .ok_or_else(|| error("There is no previous window layout to restore.".into()))?;
        clamp_rect_to_work_area(remembered, areas[monitor_for(&areas, remembered)])
    } else if matches!(
        action,
        WindowAction::NextDisplay | WindowAction::PreviousDisplay
    ) {
        if areas.len() < 2 {
            return Err(error("Connect another display to move this window.".into()));
        }
        let next = if action == WindowAction::NextDisplay {
            (source + 1) % areas.len()
        } else {
            (source + areas.len() - 1) % areas.len()
        };
        transfer_rect(current, areas[source], areas[next])
    } else {
        configured_rect(action, areas[source], current, &options, index)
    };
    let actual = match platform::set_bounds(target, desired.into()) {
        Ok(bounds) => Rect::from(bounds),
        Err(message) => {
            let _ = platform::set_bounds(target, current.into());
            *cycle = None;
            return Err(error(message));
        }
    };
    if close_bounds(actual, current) && !close_bounds(desired, current) {
        *cycle = None;
        return Err(error(
            "The application did not accept this window layout.".into(),
        ));
    }
    if restoring {
        previous.complete_restore(identity);
    } else if !options.cycle
        || !cycle.is_some_and(|step| {
            step.identity == identity && step.action == action && close_bounds(step.bounds, current)
        })
    {
        previous.remember(identity, current);
    }
    *cycle = if options.cycle && matches!(action, WindowAction::LeftHalf | WindowAction::RightHalf)
    {
        Some(CycleStep {
            identity,
            action,
            index,
            bounds: actual,
        })
    } else {
        None
    };
    if let Some(palette) = app.get_webview_window("main") {
        let _ = palette.hide();
    }
    // A successful geometry change remains successful if the OS declines a focus request.
    let _ = platform::activate(target);
    Ok(WindowActionResult {
        action: action.name().into(),
        supported: true,
        applied: true,
        message: if close_bounds(actual, desired) {
            "Window layout applied."
        } else {
            "Window resized within the application's size limits."
        }
        .into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selects_the_monitor_with_largest_overlap() {
        let areas = [
            Rect {
                x: -1920.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            Rect {
                x: 0.0,
                y: 0.0,
                width: 2560.0,
                height: 1440.0,
            },
        ];
        assert_eq!(
            monitor_for(
                &areas,
                Rect {
                    x: -300.0,
                    y: 200.0,
                    width: 800.0,
                    height: 600.0
                }
            ),
            1
        );
        assert_eq!(
            monitor_for(
                &areas,
                Rect {
                    x: -1600.0,
                    y: 200.0,
                    width: 800.0,
                    height: 600.0
                }
            ),
            0
        );
    }
}
