use serde::Serialize;
use std::process::{Command, Stdio};
use tauri::Url;

const MAXIMUM_WEB_URL_BYTES: usize = 2_048;
const MAXIMUM_WEB_SEARCH_QUERY_BYTES: usize = 1_024;
const WEB_SEARCH_URL: &str = "https://www.google.com/search";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebOpenResult {
    url: String,
}

fn has_control_character(value: &str) -> bool {
    value.chars().any(char::is_control)
}

fn authority_has_userinfo(value: &str) -> bool {
    let Some((_, after_scheme)) = value.split_once("://") else {
        return false;
    };
    let authority_end = after_scheme
        .find(['/', '?', '#'])
        .unwrap_or(after_scheme.len());
    after_scheme[..authority_end].contains('@')
}

pub(crate) fn validated_http_url(value: &str) -> Result<Url, String> {
    if value.is_empty() {
        return Err("Enter a web URL to open.".to_string());
    }
    if value.len() > MAXIMUM_WEB_URL_BYTES {
        return Err("The web URL is too long.".to_string());
    }
    if value.chars().any(char::is_whitespace) || has_control_character(value) {
        return Err(
            "The web URL contains unsupported whitespace or control characters.".to_string(),
        );
    }
    if value.contains('\\') {
        return Err("The web URL contains an unsupported backslash.".to_string());
    }

    let Some((_, after_scheme)) = value.split_once("://") else {
        return Err("The web URL must start with http:// or https://.".to_string());
    };
    let authority_end = after_scheme
        .find(['/', '?', '#'])
        .unwrap_or(after_scheme.len());
    if authority_end == 0 {
        return Err("The web URL must include a host.".to_string());
    }

    let url = Url::parse(value).map_err(|_| "The web URL is not valid.".to_string())?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err("Prism opens only HTTP and HTTPS web URLs.".to_string());
    }
    if url.host_str().is_none() {
        return Err("The web URL must include a host.".to_string());
    }
    if authority_has_userinfo(value) || !url.username().is_empty() || url.password().is_some() {
        return Err("Prism does not open web URLs containing credentials.".to_string());
    }
    if url.as_str().len() > MAXIMUM_WEB_URL_BYTES {
        return Err("The normalized web URL is too long.".to_string());
    }

    Ok(url)
}

fn web_search_url(value: &str) -> Result<Url, String> {
    if value.is_empty() {
        return Err("Enter a web search query.".to_string());
    }
    if value.len() > MAXIMUM_WEB_SEARCH_QUERY_BYTES {
        return Err("The web search query is too long.".to_string());
    }
    if value != value.trim() || has_control_character(value) {
        return Err(
            "The web search query contains unsupported whitespace or control characters."
                .to_string(),
        );
    }

    let mut url = Url::parse(WEB_SEARCH_URL)
        .map_err(|_| "Prism's web search address is not valid.".to_string())?;
    url.query_pairs_mut().append_pair("q", value);
    validated_http_url(url.as_str())
}

#[cfg(target_os = "macos")]
fn opener_command(url: &Url) -> Command {
    let mut command = Command::new("open");
    command.arg(url.as_str());
    command
}

#[cfg(target_os = "windows")]
fn opener_command(url: &Url) -> Command {
    let mut command = Command::new("rundll32.exe");
    command.arg("url.dll,FileProtocolHandler").arg(url.as_str());
    command
}

#[cfg(target_os = "linux")]
fn opener_command(url: &Url) -> Command {
    let mut command = Command::new("xdg-open");
    command.arg(url.as_str());
    command
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn open_with_platform(_url: &Url) -> Result<(), String> {
    Err("Opening web URLs is not supported on this platform.".to_string())
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn open_with_platform(url: &Url) -> Result<(), String> {
    opener_command(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("Prism could not open the default browser: {error}"))
}

#[tauri::command]
pub fn open_web_url(url: String) -> Result<WebOpenResult, String> {
    let url = validated_http_url(&url)?;
    open_with_platform(&url)?;
    Ok(WebOpenResult { url: url.into() })
}

#[tauri::command]
pub fn search_web(query: String) -> Result<WebOpenResult, String> {
    let url = web_search_url(&query)?;
    open_with_platform(&url)?;
    Ok(WebOpenResult { url: url.into() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_http_urls_with_a_host() {
        assert_eq!(
            validated_http_url("https://example.com/docs?q=prism#readme")
                .unwrap()
                .as_str(),
            "https://example.com/docs?q=prism#readme"
        );
        assert!(validated_http_url("http://localhost:3000").is_ok());
        assert!(validated_http_url("file:///tmp/prism").is_err());
        assert!(validated_http_url("https:///missing-host").is_err());
        assert!(validated_http_url("https:\\example.com").is_err());
    }

    #[test]
    fn rejects_credentials_but_allows_at_signs_outside_the_authority() {
        assert!(validated_http_url("https://user@example.com/private").is_err());
        assert!(validated_http_url("https://user:secret@example.com/private").is_err());
        assert!(validated_http_url("https://@example.com/private").is_err());
        assert!(validated_http_url("https://example.com/@prism").is_ok());
    }

    #[test]
    fn rejects_control_characters_whitespace_and_oversized_urls() {
        assert!(validated_http_url("https://example.com/line\nbreak").is_err());
        assert!(validated_http_url(" https://example.com").is_err());
        assert!(validated_http_url("https://example.com/a path").is_err());
        let oversized = format!("https://example.com/{}", "a".repeat(MAXIMUM_WEB_URL_BYTES));
        assert!(validated_http_url(&oversized).is_err());
    }

    #[test]
    fn constructs_an_encoded_https_search_url() {
        let url = web_search_url("rust URL safety & encoding").unwrap();
        assert_eq!(url.scheme(), "https");
        assert_eq!(url.host_str(), Some("www.google.com"));
        assert_eq!(
            url.query_pairs().collect::<Vec<_>>(),
            vec![("q".into(), "rust URL safety & encoding".into())]
        );
    }

    #[test]
    fn rejects_empty_control_character_and_oversized_searches() {
        assert!(web_search_url("").is_err());
        assert!(web_search_url("line\nbreak").is_err());
        assert!(web_search_url(&"a".repeat(MAXIMUM_WEB_SEARCH_QUERY_BYTES + 1)).is_err());
    }

    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    #[test]
    fn passes_the_url_as_a_single_opener_argument() {
        use std::ffi::OsStr;

        let url = validated_http_url("https://example.com/search?q=a%26b").unwrap();
        let command = opener_command(&url);
        let arguments = command.get_args().collect::<Vec<_>>();

        #[cfg(target_os = "windows")]
        assert_eq!(
            arguments,
            vec![
                OsStr::new("url.dll,FileProtocolHandler"),
                OsStr::new(url.as_str())
            ]
        );
        #[cfg(not(target_os = "windows"))]
        assert_eq!(arguments, vec![OsStr::new(url.as_str())]);
    }
}
