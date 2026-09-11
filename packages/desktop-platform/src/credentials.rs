//! Persistent OS vaults; never fall back to a plaintext preference file.
fn entry(service: &str, account: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(service, account)
        .map_err(|_| "Could not access the system credential store.".into())
}
pub fn read(service: &str, account: &str) -> Result<Option<Vec<u8>>, String> {
    match entry(service, account)?.get_secret() {
        Ok(secret) => Ok(Some(secret)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err("Unlock your system credential store and try again.".into()),
    }
}
pub fn exists(service: &str, account: &str) -> Result<bool, String> {
    #[cfg(target_os = "linux")]
    {
        // keyring's get_attributes unlocks matched Secret Service items. SearchItems
        // reports locked and unlocked object paths without requesting an unlock prompt.
        let connection = zbus::blocking::Connection::session()
            .map_err(|_| "System credential store is unavailable.")?;
        let proxy = zbus::blocking::Proxy::new(
            &connection,
            "org.freedesktop.secrets",
            "/org/freedesktop/secrets",
            "org.freedesktop.Secret.Service",
        )
        .map_err(|_| "System credential store is unavailable.")?;
        let attributes = std::collections::HashMap::from([
            ("service", service),
            ("username", account),
            ("target", "default"),
        ]);
        let (unlocked, locked): (
            Vec<zbus::zvariant::OwnedObjectPath>,
            Vec<zbus::zvariant::OwnedObjectPath>,
        ) = proxy
            .call("SearchItems", &(attributes,))
            .map_err(|_| "Could not inspect the system credential store.")?;
        return Ok(!unlocked.is_empty() || !locked.is_empty());
    }
    #[cfg(target_os = "windows")]
    // Attribute lookup avoids retrieving password bytes for status/render requests.
    match entry(service, account)?.get_attributes() {
        Ok(_) => Ok(true),
        Err(keyring::Error::NoEntry) => Ok(false),
        Err(_) => Err("Could not inspect the system credential store.".into()),
    }
}
pub fn save(service: &str, account: &str, secret: &[u8]) -> Result<(), String> {
    entry(service, account)?
        .set_secret(secret)
        .map_err(|_| "Could not save the API key in the system credential store.".into())
}
pub fn delete(service: &str, account: &str) -> Result<(), String> {
    match entry(service, account)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(_) => Err("Could not delete the API key from the system credential store.".into()),
    }
}
