use serde::Serialize;

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum LoginItemStatus {
    Unsupported,
    NotRegistered,
    Enabled,
    RequiresApproval,
    NotFound,
}

impl LoginItemStatus {
    fn from_native(value: i32) -> Self {
        match value {
            -1 => Self::Unsupported,
            0 => Self::NotRegistered,
            1 => Self::Enabled,
            2 => Self::RequiresApproval,
            _ => Self::NotFound,
        }
    }
}

#[cfg(target_os = "macos")]
extern "C" {
    fn prism_login_item_status() -> i32;
    fn prism_set_login_item(enabled: bool) -> *mut std::ffi::c_char;
    fn prism_open_login_item_settings();
}

#[tauri::command]
pub(crate) fn get_login_item_status() -> LoginItemStatus {
    #[cfg(target_os = "macos")]
    if !cfg!(debug_assertions) {
        return LoginItemStatus::from_native(unsafe { prism_login_item_status() });
    }
    LoginItemStatus::Unsupported
}

#[tauri::command]
pub(crate) fn set_login_item_enabled(enabled: bool) -> Result<LoginItemStatus, String> {
    if get_login_item_status() == LoginItemStatus::Unsupported {
        return Err("Install Prism in Applications to change login items.".into());
    }
    #[cfg(target_os = "macos")]
    unsafe {
        let error = prism_set_login_item(enabled);
        if !error.is_null() {
            let message = std::ffi::CStr::from_ptr(error)
                .to_string_lossy()
                .into_owned();
            libc::free(error.cast());
            return Err(message);
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = enabled;
    Ok(get_login_item_status())
}

#[tauri::command]
pub(crate) fn open_login_item_settings() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        unsafe { prism_open_login_item_settings() };
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    Err("Login items are available on macOS.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn maps_all_service_states_without_claiming_unknown_states_are_enabled() {
        for (value, expected) in [
            (-1, LoginItemStatus::Unsupported),
            (0, LoginItemStatus::NotRegistered),
            (1, LoginItemStatus::Enabled),
            (2, LoginItemStatus::RequiresApproval),
            (3, LoginItemStatus::NotFound),
            (99, LoginItemStatus::NotFound),
        ] {
            assert_eq!(LoginItemStatus::from_native(value), expected);
        }
    }
    #[test]
    fn serializes_approval_for_the_renderer() {
        assert_eq!(
            serde_json::to_string(&LoginItemStatus::RequiresApproval).unwrap(),
            "\"requiresApproval\""
        );
    }
}
