use std::time::{Duration, Instant};
use zeroize::Zeroizing;

// Process memory only. Never serialize this type or return its bytes to the renderer.
#[derive(Default)]
pub struct KeySession {
    key: Option<Zeroizing<Vec<u8>>>,
    denied: Option<(Instant, String)>,
}
impl KeySession {
    pub fn peek(&self) -> Option<&[u8]> {
        self.key.as_ref().map(|key| key.as_slice())
    }
    pub fn replace(&mut self, key: Vec<u8>) {
        self.key = Some(Zeroizing::new(key));
        self.denied = None;
    }
    pub fn clear(&mut self) {
        self.key = None;
        self.denied = None;
    }
    pub fn allow_retry(&mut self) {
        self.denied = None;
    }
    /// Restore previously authorized access without recording a user denial.
    /// A settings probe must not suppress the next deliberate feature request.
    pub fn load_silent(
        &mut self,
        read: impl FnOnce() -> Result<Option<Vec<u8>>, String>,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, String> {
        if self.key.is_some() {
            return Ok(self.key.clone());
        }
        if let Some(key) = read()? {
            self.replace(key);
        }
        Ok(self.key.clone())
    }
    pub fn load(
        &mut self,
        read: impl FnOnce() -> Result<Option<Vec<u8>>, String>,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, String> {
        if self.key.is_some() {
            return Ok(self.key.clone());
        }
        // Coalesce callers queued behind the same canceled macOS dialog.
        if let Some((when, error)) = &self.denied {
            if when.elapsed() < Duration::from_secs(5) {
                return Err(error.clone());
            }
        }
        match read() {
            Ok(Some(key)) => {
                self.replace(key);
                Ok(self.key.clone())
            }
            Ok(None) => {
                self.clear();
                Ok(None)
            }
            Err(error) => {
                self.denied = Some((Instant::now(), error.clone()));
                Err(error)
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn settings_denial_does_not_block_feature_authorization() {
        let mut session = KeySession::default();
        assert!(session
            .load_silent(|| Err("interaction required".into()))
            .is_err());
        assert_eq!(
            session
                .load(|| Ok(Some(b"fixture".to_vec())))
                .unwrap()
                .unwrap()
                .as_slice(),
            b"fixture"
        );
        assert!(session
            .load_silent(|| panic!("reuse authorized access"))
            .unwrap()
            .is_some());
    }
    #[test]
    fn settings_probe_does_not_clear_a_cancelled_feature_request() {
        let mut session = KeySession::default();
        assert!(session.load(|| Err("canceled".into())).is_err());
        assert!(session
            .load_silent(|| Err("interaction required".into()))
            .is_err());
        assert_eq!(
            session
                .load(|| panic!("do not reopen canceled dialog"))
                .unwrap_err(),
            "canceled"
        );
    }
    #[test]
    fn repeated_reads_share_one_authorization_and_replacement_invalidates_old_key() {
        let mut session = KeySession::default();
        assert!(session.peek().is_none());
        session
            .load(|| Ok(Some(b"fixture-first".to_vec())))
            .unwrap();
        for _ in 0..20 {
            assert_eq!(
                session
                    .load(|| panic!("must not reauthorize"))
                    .unwrap()
                    .unwrap()
                    .as_slice(),
                b"fixture-first"
            );
        }
        session.replace(b"fixture-second".to_vec());
        assert_eq!(session.peek(), Some(b"fixture-second".as_slice()));
        session.clear();
        assert!(session.peek().is_none());
        assert!(session.load(|| Ok(None)).unwrap().is_none());
    }
    #[test]
    fn cancelled_dialog_is_not_reopened_by_queued_calls() {
        let mut session = KeySession::default();
        assert!(session.load(|| Err("canceled".into())).is_err());
        assert_eq!(
            session
                .load(|| panic!("queued caller must not prompt"))
                .unwrap_err(),
            "canceled"
        );
        session.denied = Some((Instant::now() - Duration::from_secs(6), "canceled".into()));
        assert!(session
            .load(|| Ok(Some(b"fixture".to_vec())))
            .unwrap()
            .is_some());
    }
    #[test]
    fn explicit_authorization_can_retry_a_recent_silent_denial() {
        let mut session = KeySession::default();
        assert!(session
            .load(|| Err("authorization required".into()))
            .is_err());
        session.allow_retry();
        assert!(session
            .load(|| Ok(Some(b"fixture".to_vec())))
            .unwrap()
            .is_some());
        session.allow_retry();
        assert!(session
            .load(|| panic!("an authorized key stays cached"))
            .unwrap()
            .is_some());
    }
}
