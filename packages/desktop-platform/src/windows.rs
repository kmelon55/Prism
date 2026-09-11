use crate::{Bounds, Capabilities, PowerAction, TargetWindow};
use std::{path::Path, ptr};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    Security::*,
    System::{
        DataExchange::GetClipboardSequenceNumber, Power::SetSuspendState, Shutdown::*, Threading::*,
    },
    UI::{Input::KeyboardAndMouse::*, Shell::ShellExecuteW, WindowsAndMessaging::*},
};

fn failed(action: &str) -> String {
    format!("Could not {action}: {}", std::io::Error::last_os_error())
}
fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    value.encode_wide().chain(Some(0)).collect()
}

/// Enumerate the shell's application namespace, including Store apps without .lnk files.
/// Interfaces stay on this thread and are released before its COM apartment is released.
pub fn shell_applications() -> Result<Vec<(String, String)>, String> {
    use ::windows::Win32::{System::Com::*, UI::Shell::*};
    unsafe {
        let initialized = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let owns_apartment = initialized.is_ok();
        if !owns_apartment && initialized != ::windows::core::HRESULT(0x80010106u32 as i32) {
            return Err("Could not inspect installed Windows applications.".into());
        }
        struct Apartment(bool);
        impl Drop for Apartment {
            fn drop(&mut self) {
                if self.0 {
                    unsafe {
                        CoUninitialize();
                    }
                }
            }
        }
        let _apartment = Apartment(owns_apartment);
        let folder: IShellItem = SHGetKnownFolderItem(&FOLDERID_AppsFolder, KF_FLAG_DEFAULT, None)
            .map_err(|e| e.to_string())?;
        let entries: IEnumShellItems = folder
            .BindToHandler(None::<&IBindCtx>, &BHID_EnumItems)
            .map_err(|e| e.to_string())?;
        fn text(item: &IShellItem, kind: SIGDN) -> Result<String, String> {
            unsafe {
                let value = item.GetDisplayName(kind).map_err(|e| e.to_string())?;
                let text = value.to_string().map_err(|e| e.to_string());
                CoTaskMemFree(Some(value.0.cast()));
                text
            }
        }
        let mut applications = Vec::new();
        loop {
            let mut item = [None];
            let mut count = 0;
            entries
                .Next(&mut item, Some(&mut count))
                .map_err(|e| e.to_string())?;
            if count == 0 {
                break;
            }
            if let Some(item) = item[0].take() {
                if let (Ok(name), Ok(id)) = (
                    text(&item, SIGDN_NORMALDISPLAY),
                    text(&item, SIGDN_PARENTRELATIVEPARSING),
                ) {
                    if !name.is_empty() && !id.is_empty() && !id.contains('\0') {
                        applications.push((name, format!("shell:AppsFolder\\{id}")));
                    }
                }
            }
        }
        Ok(applications)
    }
}
fn hwnd(target: TargetWindow) -> Result<HWND, String> {
    let handle = target.id as HWND;
    let mut pid = 0;
    // SAFETY: the handle is validated by the OS; no pointer is dereferenced by Rust.
    unsafe {
        if target.id == 0 || IsWindow(handle) == 0 {
            return Err("The target window has closed.".into());
        }
        GetWindowThreadProcessId(handle, &mut pid);
    }
    if pid != target.pid || pid == std::process::id() {
        return Err("The target window has changed.".into());
    }
    Ok(handle)
}
pub fn capabilities() -> Capabilities {
    Capabilities {
        window_management: true,
        paste: true,
        sleep_displays: true,
        log_out: true,
        reason: None,
    }
}
pub fn foreground() -> Result<TargetWindow, String> {
    unsafe {
        let handle = GetForegroundWindow();
        let mut pid = 0;
        GetWindowThreadProcessId(handle, &mut pid);
        let target = TargetWindow {
            id: handle as usize,
            pid,
        };
        hwnd(target)?;
        Ok(target)
    }
}
pub fn bounds(target: TargetWindow) -> Result<Bounds, String> {
    let handle = hwnd(target)?;
    let mut rect = RECT::default();
    if unsafe { GetWindowRect(handle, &mut rect) } == 0 {
        return Err(failed("read the window bounds"));
    }
    Ok(Bounds {
        x: rect.left as f64,
        y: rect.top as f64,
        width: (rect.right - rect.left) as f64,
        height: (rect.bottom - rect.top) as f64,
    })
}
pub fn set_bounds(target: TargetWindow, rect: Bounds) -> Result<Bounds, String> {
    if !rect.valid() {
        return Err("Invalid window bounds.".into());
    }
    let handle = hwnd(target)?;
    unsafe {
        if IsZoomed(handle) != 0 || IsIconic(handle) != 0 {
            ShowWindow(handle, SW_RESTORE);
        }
        if SetWindowPos(
            handle,
            ptr::null_mut(),
            rect.x.round() as i32,
            rect.y.round() as i32,
            rect.width.round() as i32,
            rect.height.round() as i32,
            SWP_NOACTIVATE | SWP_NOZORDER,
        ) == 0
        {
            return Err(failed("move the window"));
        }
    }
    bounds(target)
}
pub fn activate(target: TargetWindow) -> Result<(), String> {
    let handle = hwnd(target)?;
    unsafe {
        if IsIconic(handle) != 0 {
            ShowWindow(handle, SW_RESTORE);
        }
        if SetForegroundWindow(handle) == 0 {
            return Err(
                "Windows did not allow focusing the target window. The item remains copied.".into(),
            );
        }
    }
    Ok(())
}
pub fn work_areas() -> Result<Vec<Bounds>, String> {
    unsafe extern "system" fn collect(
        monitor: HMONITOR,
        _: HDC,
        _: *mut RECT,
        data: LPARAM,
    ) -> i32 {
        let areas = &mut *(data as *mut Vec<Bounds>);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info) != 0 {
            let r = info.rcWork;
            areas.push(Bounds {
                x: r.left as f64,
                y: r.top as f64,
                width: (r.right - r.left) as f64,
                height: (r.bottom - r.top) as f64,
            });
        }
        1
    }
    let mut areas = Vec::new();
    if unsafe {
        EnumDisplayMonitors(
            ptr::null_mut(),
            ptr::null(),
            Some(collect),
            &mut areas as *mut _ as isize,
        )
    } == 0
        || areas.is_empty()
    {
        return Err(failed("enumerate monitors"));
    }
    Ok(areas)
}
pub fn clipboard_revision() -> Option<isize> {
    Some(unsafe { GetClipboardSequenceNumber() } as isize)
}
pub fn paste(target: TargetWindow) -> Result<(), String> {
    if foreground()? != target {
        return Err("The target window changed. The item remains copied.".into());
    }
    // Wait for physical shortcut modifiers to be released in the caller. Never release a user's held keys.
    if modifiers_down() {
        return Err("Release modifier keys and try again. The item remains copied.".into());
    }
    let inputs = [
        (VK_CONTROL, 0),
        (0x56, 0),
        (0x56, KEYEVENTF_KEYUP),
        (VK_CONTROL, KEYEVENTF_KEYUP),
    ]
    .map(|(key, flags)| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: key,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    });
    let sent = unsafe {
        SendInput(
            inputs.len() as u32,
            inputs.as_ptr(),
            std::mem::size_of::<INPUT>() as i32,
        )
    };
    if sent != inputs.len() as u32 {
        // Release keys from our partially inserted sequence, never held user keys.
        let release = match sent {
            1 | 3 => &inputs[3..],
            2 => &inputs[2..],
            _ => &inputs[0..0],
        };
        if !release.is_empty() {
            unsafe {
                SendInput(
                    release.len() as u32,
                    release.as_ptr(),
                    std::mem::size_of::<INPUT>() as i32,
                );
            }
        }
        return Err(
            "Windows blocked paste input (the target may be elevated). The item remains copied."
                .into(),
        );
    }
    Ok(())
}
pub fn modifiers_down() -> bool {
    [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN]
        .into_iter()
        .any(|key| unsafe { GetAsyncKeyState(key as i32) } < 0)
}
pub fn open_path(path: &Path, reveal: bool) -> Result<(), String> {
    let path = dunce::simplified(path);
    if reveal {
        // Explorer accepts /select,<path> as one argument. No shell parses the path.
        std::process::Command::new("explorer.exe")
            .arg(format!("/select,{}", path.display()))
            .spawn()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    let value = wide(path.as_os_str());
    let result = unsafe {
        ShellExecuteW(
            ptr::null_mut(),
            ptr::null(),
            value.as_ptr(),
            ptr::null(),
            ptr::null(),
            SW_SHOWNORMAL,
        )
    } as isize;
    if result <= 32 {
        Err(format!("Windows could not open this item ({result})."))
    } else {
        Ok(())
    }
}

pub fn power(action: PowerAction) -> Result<(), String> {
    match action {
        PowerAction::SleepDisplays => {
            let mut result = 0;
            if unsafe {
                SendMessageTimeoutW(
                    HWND_BROADCAST,
                    WM_SYSCOMMAND,
                    SC_MONITORPOWER as usize,
                    2,
                    SMTO_ABORTIFHUNG,
                    1000,
                    &mut result,
                )
            } == 0
            {
                Err(failed("sleep displays"))
            } else {
                Ok(())
            }
        }
        PowerAction::LogOut => session_exit(EWX_LOGOFF),
        PowerAction::Sleep | PowerAction::Restart | PowerAction::ShutDown => {
            with_shutdown_privilege(|| {
                if action == PowerAction::Sleep {
                    if !unsafe { SetSuspendState(false, false, false) } {
                        Err(failed("suspend this computer"))
                    } else {
                        Ok(())
                    }
                } else {
                    session_exit(if action == PowerAction::Restart {
                        EWX_REBOOT
                    } else {
                        EWX_POWEROFF
                    })
                }
            })
        }
    }
}
fn session_exit(flags: u32) -> Result<(), String> {
    // No EWX_FORCE / EWX_FORCEIFHUNG: applications retain their normal close veto.
    if unsafe {
        ExitWindowsEx(
            flags,
            SHTDN_REASON_MAJOR_APPLICATION | SHTDN_REASON_FLAG_PLANNED,
        )
    } == 0
    {
        Err(failed("request the session action"))
    } else {
        Ok(())
    }
}
fn with_shutdown_privilege(work: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
    let mut token = ptr::null_mut();
    if unsafe {
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )
    } == 0
    {
        return Err(failed("open the process token"));
    }
    struct Token(HANDLE, Option<TOKEN_PRIVILEGES>);
    impl Drop for Token {
        fn drop(&mut self) {
            unsafe {
                if let Some(previous) = self.1.as_ref() {
                    AdjustTokenPrivileges(self.0, 0, previous, 0, ptr::null_mut(), ptr::null_mut());
                }
                CloseHandle(self.0);
            }
        }
    }
    let mut guard = Token(token, None);
    let mut luid = LUID::default();
    let name = wide(std::ffi::OsStr::new("SeShutdownPrivilege"));
    if unsafe { LookupPrivilegeValueW(ptr::null(), name.as_ptr(), &mut luid) } == 0 {
        return Err(failed("look up shutdown permission"));
    }
    let requested = TOKEN_PRIVILEGES {
        PrivilegeCount: 1,
        Privileges: [LUID_AND_ATTRIBUTES {
            Luid: luid,
            Attributes: SE_PRIVILEGE_ENABLED,
        }],
    };
    let mut previous = TOKEN_PRIVILEGES::default();
    let mut length = 0;
    let granted = unsafe {
        SetLastError(0);
        AdjustTokenPrivileges(
            token,
            0,
            &requested,
            std::mem::size_of::<TOKEN_PRIVILEGES>() as u32,
            &mut previous,
            &mut length,
        ) != 0
            && GetLastError() == 0
    };
    if !granted {
        return Err("Windows did not grant shutdown permission.".into());
    }
    guard.1 = Some(previous);
    work()
}
