//! Password reads may prompt only through an explicit key-authorization action.
use core_foundation::{
    base::TCFType,
    string::{CFString, CFStringRef},
};
use security_framework::passwords::{generic_password, PasswordOptions};

#[link(name = "Security", kind = "framework")]
extern "C" {
    static kSecUseAuthenticationUI: CFStringRef;
    static kSecUseAuthenticationUIFail: CFStringRef;
}

fn options(service: &str, account: &str, allow_prompt: bool) -> PasswordOptions {
    let mut options = PasswordOptions::new_generic_password(service, account);
    if !allow_prompt {
        // security-framework 3.7 has no setter for AuthenticationUIFail. Set only
        // this query's policy; do not disable interaction process-wide or change ACLs.
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
    match generic_password(options(service, account, allow_prompt)) {
        Ok(key) => Ok(Some(key)),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(_) => Err("저장된 키를 사용하려면 설정에서 ‘키 사용 허용’을 눌러 주세요.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
