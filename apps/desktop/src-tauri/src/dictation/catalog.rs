//! Catalog decoding/filtering/order/pricing ported from Whisp VercelModelCatalog.swift.
//! Copyright (c) 2026 Whisp contributors. MIT; see native/dictation/LICENSE-Whisp.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    id: String,
    name: String,
    description: String,
    owned_by: String,
    batch_compatible: bool,
    unavailable_reason: Option<&'static str>,
    free: bool,
    pricing: Value,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    models: Vec<Model>,
    source: String,
    mode: &'static str,
}
#[derive(Deserialize)]
struct Response {
    data: Vec<Value>,
}
fn strings(value: &Value, field: &str, member: &str) -> bool {
    value[field]
        .as_array()
        .is_some_and(|list| list.iter().any(|item| item.as_str() == Some(member)))
}
fn documented_openai(id: &str) -> bool {
    [
        "whisper-1",
        "gpt-transcribe",
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
        "gpt-4o-transcribe-diarize",
    ]
    .iter()
    .any(|base| {
        id == *base
            || id.strip_prefix(&format!("{base}-")).is_some_and(|date| {
                date.len() == 10
                    && date.bytes().enumerate().all(|(i, b)| {
                        if i == 4 || i == 7 {
                            b == b'-'
                        } else {
                            b.is_ascii_digit()
                        }
                    })
            })
    })
}
fn decode(provider: &str, body: &[u8]) -> Result<Vec<Model>, String> {
    let response: Response =
        serde_json::from_slice(body).map_err(|_| "모델 목록 응답을 읽지 못했습니다.")?;
    let mut seen = std::collections::HashSet::new();
    let mut models = Vec::new();
    for row in response.data {
        let Some(id) = row["id"].as_str().filter(|id| {
            !id.is_empty() && id.len() <= 200 && id.bytes().all(|b| b.is_ascii_graphic())
        }) else {
            continue;
        };
        if row["active"] == false {
            continue;
        }
        let transcription = row["type"] == "transcription";
        let include = match provider {
            "vercel" => transcription && strings(&row, "supported_specifications", "v4"),
            "openai" => documented_openai(id),
            "groq" => matches!(id, "whisper-large-v3" | "whisper-large-v3-turbo"),
            // Compatible servers must explicitly advertise transcription capability.
            // An audio input modality alone does not prove a file transcription endpoint.
            "custom" => {
                transcription || strings(&row, "supported_endpoints", "/v1/audio/transcriptions")
            }
            _ => false,
        };
        if !include || !seen.insert(id.to_owned()) {
            continue;
        }
        let realtime = strings(&row, "tags", "websocket-realtime")
            || id.ends_with("-live")
            || id.contains("realtime");
        let diarize = provider == "openai" && id.contains("diarize");
        models.push(Model {
            id: id.to_owned(),
            name: row["name"]
                .as_str()
                .unwrap_or(id)
                .chars()
                .take(200)
                .collect(),
            description: row["description"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(600)
                .collect(),
            owned_by: row["owned_by"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(100)
                .collect(),
            batch_compatible: !realtime && !diarize,
            unavailable_reason: if realtime {
                Some("실시간 전용 모델")
            } else if diarize {
                Some("화자 분리 옵션은 아직 지원하지 않습니다.")
            } else {
                None
            },
            free: strings(&row, "tags", "free"),
            pricing: row["pricing"].clone(),
        });
    }
    // Whisp's preferred ordering, applied only to models actually returned by the API.
    let preferred = [
        "openai/gpt-4o-mini-transcribe",
        "openai/gpt-4o-transcribe",
        "google/gemini-3.5-transcribe",
        "spacexai/grok-stt",
        "fish-audio/transcribe-1-free",
        "fish-audio/transcribe-1",
        "openai/whisper-1",
        "google/gemini-3.5-transcribe-live",
        "openai/gpt-realtime-whisper",
    ];
    models.sort_by_key(|m| {
        (
            preferred
                .iter()
                .position(|id| *id == m.id)
                .unwrap_or(usize::MAX),
            m.name.to_lowercase(),
        )
    });
    Ok(models)
}
fn endpoint(provider: &str, base_url: &str) -> Result<String, String> {
    let settings = super::DictationSettings {
        provider: provider.into(),
        model: "catalog".into(),
        base_url: base_url.into(),
        ..Default::default()
    };
    settings.validate()?;
    if provider == "local" {
        return Err("로컬 모델 파일을 선택하세요.".into());
    }
    Ok(if provider == "vercel" {
        "https://ai-gateway.vercel.sh/v1/models".into()
    } else {
        format!(
            "{}/models",
            base_url
                .trim_end_matches('/')
                .trim_end_matches("/audio/transcriptions")
        )
    })
}
#[tauri::command]
pub async fn dictation_list_models(provider: String, base_url: String) -> Result<Catalog, String> {
    let source = endpoint(&provider, &base_url)?;
    // xAI /stt selects its engine server-side and accepts no model argument.
    // Do not present the language-model catalog as STT model availability.
    if provider == "xai" {
        return Ok(Catalog {
            models: vec![],
            source: "https://api.x.ai/v1/stt".into(),
            mode: "fixed",
        });
    }
    let key_provider = provider.clone();
    let key = if provider == "vercel" {
        None
    } else {
        Some(
            tauri::async_runtime::spawn_blocking(move || super::read_provider_key(&key_provider))
                .await
                .map_err(|_| "키체인 작업을 완료하지 못했습니다.")??,
        )
    };
    let body = fetch_catalog(&source, key.as_deref().map(|key| key.as_slice())).await?;
    Ok(Catalog {
        models: decode(&provider, &body)?,
        source,
        mode: "catalog",
    })
}
async fn fetch_catalog(source: &str, key: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "모델 목록 연결을 준비하지 못했습니다.")?;
    let mut request = client.get(source);
    if let Some(key) = key {
        let key = std::str::from_utf8(key).map_err(|_| "API 키 형식이 올바르지 않습니다.")?;
        request = request.bearer_auth(key);
    }
    let mut response = request
        .send()
        .await
        .map_err(|_| "모델 목록에 연결하지 못했습니다. 네트워크와 API 주소를 확인하세요.")?;
    if !response.status().is_success() {
        return Err(format!(
            "모델 목록 오류 ({}). API 키와 접근 권한을 확인한 뒤 새로고침하세요.",
            response.status().as_u16()
        ));
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "모델 목록을 끝까지 읽지 못했습니다.")?
    {
        if body.len() + chunk.len() > 4 * 1024 * 1024 {
            return Err("모델 목록 응답이 너무 큽니다.".into());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn server(
        status: &str,
        headers: &str,
        body: Vec<u8>,
    ) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/v1/models", listener.local_addr().unwrap());
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n",
            body.len()
        );
        let thread = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let mut buf = [0; 1024];
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let count = stream.read(&mut buf).unwrap();
                if count == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..count]);
            }
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.write_all(&body);
            String::from_utf8(request).unwrap()
        });
        (url, thread)
    }
    #[tokio::test]
    async fn catalog_transport_only_gets_and_never_follows_redirects_or_echoes_errors() {
        let (url, request) = server("200 OK", "", br#"{"data":[]}"#.to_vec());
        assert_eq!(
            fetch_catalog(&url, Some(b"fixture-key")).await.unwrap(),
            br#"{"data":[]}"#
        );
        let request = request.join().unwrap();
        assert!(request.starts_with("GET /v1/models HTTP/1.1"));
        assert!(request
            .to_lowercase()
            .contains("authorization: bearer fixture-key"));
        let (url, request) = server(
            "302 Found",
            "Location: https://should-never-contact.invalid/\r\n",
            b"fixture-secret".to_vec(),
        );
        let error = fetch_catalog(&url, Some(b"fixture-key")).await.unwrap_err();
        assert!(error.contains("302") && !error.contains("fixture-secret"));
        request.join().unwrap();
        let (url, request) = server("401 Unauthorized", "", b"fixture-secret".to_vec());
        let error = fetch_catalog(&url, None).await.unwrap_err();
        assert!(error.contains("401") && !error.contains("fixture-secret"));
        assert!(!request
            .join()
            .unwrap()
            .to_lowercase()
            .contains("authorization:"));
    }
    #[tokio::test]
    async fn catalog_transport_bounds_response_size() {
        let (url, request) = server("200 OK", "", vec![b' '; 4 * 1024 * 1024 + 1]);
        assert!(fetch_catalog(&url, None)
            .await
            .unwrap_err()
            .contains("너무 큽니다"));
        request.join().unwrap();
    }
    #[test]
    fn vercel_filters_live_response_and_preserves_realtime_disabled() {
        let models = decode("vercel", br#"{"data":[{"id":"chat","type":"language"},{"id":"old","type":"transcription"},{"id":"google/gemini-3.5-transcribe-live","type":"transcription","supported_specifications":["v4"]},{"id":"openai/gpt-4o-mini-transcribe","type":"transcription","supported_specifications":["v4"],"pricing":{"input":"0.1"}}]}"#).unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "openai/gpt-4o-mini-transcribe");
        assert!(models[0].batch_compatible);
        assert!(!models[1].batch_compatible);
        assert_eq!(models[0].pricing["input"], "0.1");
    }
    #[test]
    fn membership_is_live_and_audio_chat_is_not_stt() {
        let data = br#"{"data":[{"id":"gpt-4o-audio"},{"id":"gpt-transcribe"},{"id":"gpt-4o-mini-transcribe-2025-12-15"},{"id":"gpt-4o-transcribe-diarize"},{"id":"gpt-4o-transcribe-unknown"}]}"#;
        let models = decode("openai", data).unwrap();
        assert_eq!(models.len(), 3);
        assert!(
            !models
                .iter()
                .find(|m| m.id.contains("diarize"))
                .unwrap()
                .batch_compatible
        );
        assert!(decode("groq", data).unwrap().is_empty());
        assert!(decode("custom", data).unwrap().is_empty());
        assert!(decode("vercel", br#"{"data":[]}"#).unwrap().is_empty());
        assert!(decode("vercel", br#"{"error":"secret"}"#).is_err());
    }
    #[test]
    fn public_catalog_snapshot_uses_whisp_batch_filter_and_order() {
        let rows = decode(
            "vercel",
            include_bytes!("fixtures/vercel-transcription-2026-09-10.json"),
        )
        .unwrap();
        assert_eq!(rows.len(), 9);
        assert_eq!(rows.iter().filter(|m| m.batch_compatible).count(), 7);
        assert_eq!(rows[0].id, "openai/gpt-4o-mini-transcribe");
        assert!(rows
            .iter()
            .any(|m| m.id == "spacexai/grok-stt" && m.batch_compatible));
    }
    #[test]
    fn catalog_cannot_redirect_shared_keys_to_other_hosts() {
        assert!(endpoint("openai", "https://evil.test/v1").is_err());
        assert!(endpoint("custom", "http://evil.test/v1").is_err());
        assert_eq!(
            endpoint("custom", "http://127.0.0.1:9000/v1/audio/transcriptions").unwrap(),
            "http://127.0.0.1:9000/v1/models"
        );
        assert_eq!(
            endpoint("vercel", "https://ai-gateway.vercel.sh/v4/ai").unwrap(),
            "https://ai-gateway.vercel.sh/v1/models"
        );
    }
}
