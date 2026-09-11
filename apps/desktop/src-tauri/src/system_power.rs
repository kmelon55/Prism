//! Fixed system action plans. Tests substitute both confirmation and execution;
//! they must never send power events to the host.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SystemAction {
    Sleep,
    SleepDisplays,
    Restart,
    ShutDown,
    LogOut,
}

impl SystemAction {
    pub(crate) fn parse(id: &str) -> Result<Self, String> {
        match id {
            "system:sleep" => Ok(Self::Sleep),
            "system:sleep-displays" => Ok(Self::SleepDisplays),
            "system:restart" => Ok(Self::Restart),
            "system:shutdown" => Ok(Self::ShutDown),
            "system:log-out" => Ok(Self::LogOut),
            _ => Err("Unknown system action.".into()),
        }
    }

    pub(crate) fn needs_confirmation(self) -> bool {
        matches!(self, Self::Restart | Self::ShutDown | Self::LogOut)
    }

    pub(crate) fn title(self, korean: bool) -> &'static str {
        match (self, korean) {
            (Self::Sleep, false) => "Sleep",
            (Self::Sleep, true) => "잠자기",
            (Self::SleepDisplays, false) => "Sleep Displays",
            (Self::SleepDisplays, true) => "디스플레이 잠자기",
            (Self::Restart, false) => "Restart",
            (Self::Restart, true) => "재시동",
            (Self::ShutDown, false) => "Shut Down",
            (Self::ShutDown, true) => "시스템 종료",
            (Self::LogOut, false) => "Log Out",
            (Self::LogOut, true) => "로그아웃",
        }
    }

    fn event_id(self) -> Option<u32> {
        // AERegistry.h: normal session requests, never forced termination.
        match self {
            Self::Sleep => Some(u32::from_be_bytes(*b"slep")),
            Self::Restart => Some(u32::from_be_bytes(*b"rest")),
            Self::ShutDown => Some(u32::from_be_bytes(*b"shut")),
            Self::LogOut => Some(u32::from_be_bytes(*b"logo")),
            Self::SleepDisplays => None,
        }
    }
}

pub(crate) fn run_with(
    action: SystemAction,
    confirm: impl FnOnce(SystemAction) -> bool,
    execute: impl FnOnce(SystemAction) -> Result<(), String>,
) -> Result<bool, String> {
    if action.needs_confirmation() && !confirm(action) {
        return Ok(false);
    }
    execute(action)?;
    Ok(true)
}

#[cfg(target_os = "macos")]
pub(crate) fn execute(action: SystemAction) -> Result<(), String> {
    if let Some(event_id) = action.event_id() {
        send_session_event(event_id)
    } else {
        let status = std::process::Command::new("/usr/bin/pmset")
            .arg("displaysleepnow")
            .status()
            .map_err(|error| format!("Could not sleep displays: {error}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("macOS declined Sleep Displays ({status})."))
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn execute(action: SystemAction) -> Result<(), String> {
    use prism_desktop_platform::PowerAction as P;
    prism_desktop_platform::power(match action {
        SystemAction::Sleep => P::Sleep,
        SystemAction::SleepDisplays => P::SleepDisplays,
        SystemAction::Restart => P::Restart,
        SystemAction::ShutDown => P::ShutDown,
        SystemAction::LogOut => P::LogOut,
    })
}

#[cfg(target_os = "macos")]
fn send_session_event(event_id: u32) -> Result<(), String> {
    use std::{ffi::c_void, ptr};

    // AEDataModel.h uses two-byte packing, including on arm64.
    #[repr(C, packed(2))]
    struct Descriptor {
        kind: u32,
        data: *mut c_void,
    }
    impl Descriptor {
        fn empty() -> Self {
            Self {
                kind: 0,
                data: ptr::null_mut(),
            }
        }
    }
    #[link(name = "CoreServices", kind = "framework")]
    extern "C" {
        fn AECreateDesc(
            kind: u32,
            data: *const c_void,
            size: isize,
            result: *mut Descriptor,
        ) -> i16;
        fn AECreateAppleEvent(
            class: u32,
            id: u32,
            target: *const Descriptor,
            return_id: i16,
            transaction: i32,
            result: *mut Descriptor,
        ) -> i16;
        fn AESendMessage(
            event: *const Descriptor,
            reply: *mut Descriptor,
            mode: i32,
            timeout: isize,
        ) -> i32;
        fn AEDisposeDesc(descriptor: *mut Descriptor) -> i16;
    }
    impl Drop for Descriptor {
        fn drop(&mut self) {
            // SAFETY: initialized descriptors are owned here; null descriptors are disposable.
            unsafe {
                AEDisposeDesc(self);
            }
        }
    }

    // The system process (kSystemProcess), not an arbitrary renderer-selected target.
    let system_process: [u32; 2] = [0, 1];
    let mut target = Descriptor::empty();
    let mut event = Descriptor::empty();
    // SAFETY: fixed-size buffers and descriptors remain alive through each synchronous call.
    let status = unsafe {
        AECreateDesc(
            u32::from_be_bytes(*b"psn "),
            system_process.as_ptr().cast(),
            8,
            &mut target,
        )
    };
    if status != 0 {
        return Err(format!("Could not address the macOS session ({status})."));
    }
    // SAFETY: target is a live owned AEDesc; event receives a separately owned descriptor.
    let status = unsafe {
        AECreateAppleEvent(
            u32::from_be_bytes(*b"aevt"),
            event_id,
            &target,
            -1,
            0,
            &mut event,
        )
    };
    if status != 0 {
        return Err(format!(
            "Could not create the macOS session request ({status})."
        ));
    }
    // kAENoReply | kAECanInteract: apps may still ask to save documents or cancel.
    // Success means the request was sent, not that shutdown/logout has completed.
    // SAFETY: event is live; a null reply is permitted with kAENoReply.
    let status = unsafe { AESendMessage(&event, ptr::null_mut(), 0x01 | 0x20, -1) };
    if status == 0 {
        Ok(())
    } else {
        Err(format!("macOS declined the session request ({status})."))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_exact_allowlisted_ids_resolve() {
        for id in [
            "/usr/bin/pmset",
            "system:restart; reboot",
            "system:force-shutdown",
            "rest",
            "system:settings:power-battery",
        ] {
            assert!(SystemAction::parse(id).is_err());
        }
        for id in [
            "system:sleep",
            "system:sleep-displays",
            "system:restart",
            "system:shutdown",
            "system:log-out",
        ] {
            assert!(SystemAction::parse(id).is_ok());
        }
    }

    #[test]
    fn cancellation_never_reaches_execution() {
        for action in [
            SystemAction::Restart,
            SystemAction::ShutDown,
            SystemAction::LogOut,
        ] {
            assert!(!run_with(action, |_| false, |_| panic!("cancelled action executed")).unwrap());
        }
    }

    #[test]
    fn approved_actions_route_once_and_preserve_failures() {
        for action in [
            SystemAction::Restart,
            SystemAction::ShutDown,
            SystemAction::LogOut,
        ] {
            let mut calls = 0;
            assert!(run_with(
                action,
                |requested| requested == action,
                |requested| {
                    assert_eq!(requested, action);
                    calls += 1;
                    Ok(())
                }
            )
            .unwrap());
            assert_eq!(calls, 1);
            assert_eq!(
                run_with(action, |_| true, |_| Err("denied".into())),
                Err("denied".into())
            );
        }
    }

    #[test]
    fn sleep_actions_do_not_require_confirmation() {
        for action in [SystemAction::Sleep, SystemAction::SleepDisplays] {
            assert!(run_with(action, |_| panic!("unexpected confirmation"), |_| Ok(())).unwrap());
        }
    }

    #[test]
    fn plans_use_normal_session_events() {
        assert_eq!(
            SystemAction::Sleep.event_id(),
            Some(u32::from_be_bytes(*b"slep"))
        );
        assert_eq!(
            SystemAction::Restart.event_id(),
            Some(u32::from_be_bytes(*b"rest"))
        );
        assert_eq!(
            SystemAction::ShutDown.event_id(),
            Some(u32::from_be_bytes(*b"shut"))
        );
        assert_eq!(
            SystemAction::LogOut.event_id(),
            Some(u32::from_be_bytes(*b"logo"))
        );
        assert_eq!(SystemAction::SleepDisplays.event_id(), None);
    }
}
