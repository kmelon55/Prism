//! Password reads may prompt only through an explicit key-authorization action.
use core_foundation::{
    base::TCFType,
    string::{CFString, CFStringRef},
};
use security_framework::{
    base::{Error, Result as SecurityResult},
    item::{ItemClass, ItemSearchOptions},
    passwords::{generic_password, PasswordOptions},
};
use std::sync::Mutex;

// The login (file-based) keychain does not reliably honor SecItem's per-query
// authentication UI policy. Serialize every Prism Keychain operation so a silent
// read cannot suppress an explicit save/unlock in another provider.
static OPERATIONS: Mutex<()> = Mutex::new(());

struct InteractionPolicy(u8);
impl Drop for InteractionPolicy {
    fn drop(&mut self) {
        let status = unsafe { SecKeychainSetUserInteractionAllowed(self.0) };
        if status != 0 {
            eprintln!("Could not restore Keychain interaction policy: {status}");
        }
    }
}

fn with_interaction<T>(
    allow_prompt: bool,
    operation: impl FnOnce() -> SecurityResult<T>,
) -> SecurityResult<T> {
    let _operation = OPERATIONS.lock().map_err(|_| Error::from_code(-2070))?;
    let _policy = if allow_prompt {
        None
    } else {
        let mut previous = 0;
        let status = unsafe { SecKeychainGetUserInteractionAllowed(&mut previous) };
        if status != 0 {
            return Err(Error::from_code(status));
        }
        let status = unsafe { SecKeychainSetUserInteractionAllowed(0) };
        if status != 0 {
            return Err(Error::from_code(status));
        }
        Some(InteractionPolicy(previous))
    };
    operation()
}

#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecKeychainGetUserInteractionAllowed(state: *mut u8) -> i32;
    fn SecKeychainSetUserInteractionAllowed(state: u8) -> i32;
    static kSecUseAuthenticationUI: CFStringRef;
    static kSecUseAuthenticationUIFail: CFStringRef;
}

fn options(service: &str, account: &str, allow_prompt: bool) -> PasswordOptions {
    let mut options = PasswordOptions::new_generic_password(service, account);
    if !allow_prompt {
        // security-framework 3.7 has no setter for AuthenticationUIFail. Set
        // this query's policy as well as the scoped legacy-keychain guard below.
        #[allow(deprecated)]
        unsafe {
            options.query.push((
                CFString::wrap_under_get_rule(kSecUseAuthenticationUI),
                CFString::wrap_under_get_rule(kSecUseAuthenticationUIFail).into_CFType(),
            ));
        }
    }
    options
}

pub fn read(service: &str, account: &str, allow_prompt: bool) -> Result<Option<Vec<u8>>, String> {
    match with_interaction(allow_prompt, || {
        generic_password(options(service, account, allow_prompt))
    }) {
        Ok(key) => Ok(Some(key)),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(_) => Err("저장된 키를 사용하려면 설정에서 ‘키 사용 허용’을 눌러 주세요.".into()),
    }
}

/// Metadata fallback for keys that still need explicit authorization.
pub fn exists(service: &str, account: &str) -> SecurityResult<bool> {
    with_interaction(false, || {
        let mut query = ItemSearchOptions::new();
        query
            .class(ItemClass::generic_password())
            .service(service)
            .account(account)
            .load_attributes(true)
            .load_data(false)
            .limit(1);
        match query.search() {
            Ok(items) => Ok(!items.is_empty()),
            Err(error) if error.code() == -25300 => Ok(false),
            Err(error) => Err(error),
        }
    })
}

pub fn save(service: &str, account: &str, key: &[u8]) -> SecurityResult<()> {
    with_interaction(true, || {
        security_framework::passwords::set_generic_password(service, account, key)
    })
}

pub fn delete(service: &str, account: &str) -> SecurityResult<()> {
    with_interaction(true, || {
        security_framework::passwords::delete_generic_password(service, account)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn silent_policy_restores_the_previous_state_after_success_and_error() {
        // No credentials are accessed. Check the real macOS process policy while
        // serialized with every other Keychain operation in this test process.
        for fail in [false, true] {
            let result = with_interaction(false, || {
                let mut current = 1;
                assert_eq!(
                    unsafe { SecKeychainGetUserInteractionAllowed(&mut current) },
                    0
                );
                assert_eq!(current, 0);
                if fail {
                    Err(Error::from_code(-25308))
                } else {
                    Ok(())
                }
            });
            assert_eq!(result.is_err(), fail);
            with_interaction(true, || {
                let mut current = 0;
                assert_eq!(
                    unsafe { SecKeychainGetUserInteractionAllowed(&mut current) },
                    0
                );
                assert_eq!(current, 1);
                Ok(())
            })
            .unwrap();
        }
    }

    #[test]
    #[allow(deprecated)]
    fn ordinary_reads_fail_without_opening_an_authentication_dialog() {
        let policy = unsafe { CFString::wrap_under_get_rule(kSecUseAuthenticationUI) };
        let fail =
            unsafe { CFString::wrap_under_get_rule(kSecUseAuthenticationUIFail).into_CFType() };
        assert!(options("fixture", "fixture", false)
            .query
            .iter()
            .any(|(key, value)| key == &policy && value == &fail));
        assert!(!options("fixture", "fixture", true)
            .query
            .iter()
            .any(|(key, _)| key == &policy));
    }
}
