use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
static MODEL_CACHE: OnceLock<Mutex<std::collections::HashMap<String, (Instant, Vec<AiModel>)>>> =
    OnceLock::new();
use tauri::State;
use tokio::sync::oneshot;

static KEY_SESSIONS: OnceLock<
    Mutex<std::collections::HashMap<&'static str, crate::ai_key_session::KeySession>>,
> = OnceLock::new();
fn key_sessions(
) -> &'static Mutex<std::collections::HashMap<&'static str, crate::ai_key_session::KeySession>> {
    KEY_SESSIONS.get_or_init(Default::default)
}
pub(crate) fn read_key(provider: Provider) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>, String> {
    key_sessions()
        .lock()
        .map_err(|_| "AI 키 상태를 읽지 못했습니다.")?
        .entry(provider.account())
        .or_default()
        .load(|| read_key_storage(provider))
}
fn cached_key(provider: Provider) -> Result<zeroize::Zeroizing<Vec<u8>>, String> {
    key_sessions()
        .try_lock()
        .map_err(|_| "키 사용 승인이 진행 중입니다. 잠시 후 다시 시도하세요.")?
        .get(provider.account())
        .and_then(|session| session.peek())
        .map(|key| zeroize::Zeroizing::new(key.to_vec()))
        .ok_or_else(|| "AI 설정에서 ‘키 사용 허용’을 누르면 모델을 불러올 수 있습니다.".into())
}
const SERVICE: &str = "dev.prism.desktop.ai";
const MAX_BODY: usize = 1_048_576;
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Openai,
    Openrouter,
    Vercel,
}
impl Provider {
    pub(crate) fn account(self) -> &'static str {
        match self {
            Self::Openai => "openai",
            Self::Openrouter => "openrouter",
            Self::Vercel => "vercel",
        }
    }
    fn endpoint(self) -> &'static str {
        match self {
            Self::Openai => "https://api.openai.com/v1/responses",
            Self::Openrouter => "https://openrouter.ai/api/v1/chat/completions",
            Self::Vercel => "https://ai-gateway.vercel.sh/v1/chat/completions",
        }
    }
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Message {
    role: String,
    content: String,
}
#[derive(Default)]
pub struct AiRequests(Mutex<std::collections::HashMap<String, oneshot::Sender<()>>>);

#[cfg(target_os = "macos")]
fn read_key_storage(provider: Provider) -> Result<Option<Vec<u8>>, String> {
    crate::keychain::read(SERVICE, provider.account(), false)
}
#[cfg(not(target_os = "macos"))]
fn read_key_storage(provider: Provider) -> Result<Option<Vec<u8>>, String> {
    prism_desktop_platform::credentials::read(SERVICE, provider.account())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyInfo {
    pub(crate) configured: bool,
    pub(crate) masked_key: Option<String>,
    pub(crate) unlocked: bool,
}
pub(crate) fn key_info(key: Option<&[u8]>) -> KeyInfo {
    KeyInfo {
        configured: key.is_some(),
        unlocked: key.is_some(),
        masked_key: key.map(|bytes| {
            let suffix = if bytes.len() >= 12 {
                std::str::from_utf8(&bytes[bytes.len() - 4..]).unwrap_or("")
            } else {
                ""
            };
            format!("•••• •••• {suffix}").trim().to_owned()
        }),
    }
}
// Attributes-only lookup: status/focus/render effects never request password bytes.
fn inspect_key(provider: Provider) -> Result<KeyInfo, String> {
    let cache = key_sessions()
        .lock()
        .map_err(|_| "AI 키 상태를 읽지 못했습니다.")?;
    if let Some(key) = cache
        .get(provider.account())
        .and_then(|session| session.peek())
    {
        return Ok(key_info(Some(key)));
    }
    #[cfg(target_os = "macos")]
    {
        use security_framework::item::{ItemClass, ItemSearchOptions};
        let mut query = ItemSearchOptions::new();
        query
            .class(ItemClass::generic_password())
            .service(SERVICE)
            .account(provider.account())
            .load_attributes(true)
            .load_data(false)
            .limit(1)
            .skip_authenticated_items(true);
        match query.search() {
            Ok(items) => Ok(KeyInfo {
                configured: !items.is_empty(),
                masked_key: None,
                unlocked: false,
            }),
            Err(e) if e.code() == -25300 => Ok(key_info(None)),
            Err(_) => {
                Err("키 저장 상태를 확인하지 못했습니다. 키체인 잠금 상태를 확인하세요.".into())
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(KeyInfo {
            configured: prism_desktop_platform::credentials::exists(SERVICE, provider.account())?,
            masked_key: None, unlocked: false,
        })
    }
}
#[tauri::command]
pub async fn ai_key_info(provider: Provider) -> Result<KeyInfo, String> {
    tauri::async_runtime::spawn_blocking(move || inspect_key(provider))
        .await
        .map_err(|_| "키체인 작업을 완료하지 못했습니다.".to_string())?
}
#[tauri::command]
pub async fn ai_key_status(provider: Provider) -> Result<bool, String> {
    ai_key_info(provider).await.map(|info| info.configured)
}
#[tauri::command]
pub async fn ai_unlock_key(provider: Provider) -> Result<KeyInfo, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut sessions = key_sessions().lock().map_err(|_| "AI 키 상태를 읽지 못했습니다.")?;
        let session = sessions.entry(provider.account()).or_default();
        session.allow_retry();
        #[cfg(target_os = "macos")]
        let key = session.load(|| crate::keychain::read(SERVICE, provider.account(), true))?;
        #[cfg(not(target_os = "macos"))]
        let key = session.load(|| read_key_storage(provider))?;
        Ok(key_info(key.as_ref().map(|key| key.as_slice())))
    })
    .await
    .map_err(|_| "키체인 작업을 완료하지 못했습니다.".to_string())?
}
#[tauri::command]
pub async fn ai_save_key(provider: Provider, key: String) -> Result<KeyInfo, String> {
    let key = key.trim().to_owned();
    if key.is_empty() || key.len() > 4096 || !key.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("공백이나 줄바꿈이 없는 API 키를 입력하세요.".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let mut sessions = key_sessions()
                .lock()
                .map_err(|_| "AI 키 상태를 읽지 못했습니다.")?;
            security_framework::passwords::set_generic_password(
                SERVICE,
                provider.account(),
                key.as_bytes(),
            )
            .map_err(|_| "API 키를 키체인에 저장하지 못했습니다.".to_string())?;
            // Successful SecItemAdd/Update is the write acknowledgement. Re-reading here
            // can cause a second dialog for the same user action on ad-hoc builds.
            sessions
                .entry(provider.account())
                .or_default()
                .replace(key.as_bytes().to_vec());
            Ok(key_info(Some(key.as_bytes())))
        }
        #[cfg(not(target_os = "macos"))]
        {
            let mut sessions = key_sessions().lock().map_err(|_| "Could not access API key state.")?;
            prism_desktop_platform::credentials::save(SERVICE, provider.account(), key.as_bytes())?;
            sessions.entry(provider.account()).or_default().replace(key.as_bytes().to_vec());
            Ok(key_info(Some(key.as_bytes())))
        }
    })
    .await
    .map_err(|_| "키체인 작업을 완료하지 못했습니다.".to_string())?
}
#[tauri::command]
pub async fn ai_delete_key(provider: Provider) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let mut sessions = key_sessions()
                .lock()
                .map_err(|_| "AI 키 상태를 읽지 못했습니다.")?;
            match security_framework::passwords::delete_generic_password(
                SERVICE,
                provider.account(),
            ) {
                Ok(()) => {
                    sessions.remove(provider.account());
                    Ok(())
                }
                Err(error) if error.code() == -25300 => {
                    sessions.remove(provider.account());
                    Ok(())
                }
                Err(_) => Err("API 키를 삭제하지 못했습니다.".to_string()),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let mut sessions = key_sessions().lock().map_err(|_| "Could not access API key state.")?;
            prism_desktop_platform::credentials::delete(SERVICE, provider.account())?;
            sessions.remove(provider.account());
            Ok(())
        }
    })
    .await
    .map_err(|_| "키체인 작업을 완료하지 못했습니다.".to_string())?
}
fn validate(model: &str, messages: &[Message]) -> Result<(), String> {
    if model.is_empty() || model.len() > 200 || !model.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("올바른 모델 ID를 입력하세요.".into());
    }
    if messages.is_empty()
        || messages.len() > 40
        || messages.last().map(|m| m.role.as_str()) != Some("user")
        || messages.iter().enumerate().any(|(i, m)| {
            m.role != if i % 2 == 0 { "user" } else { "assistant" }
                || m.content.trim().is_empty()
                || m.content.len() > 32_000
        })
        || messages.iter().map(|m| m.content.len()).sum::<usize>() > 128_000
    {
        return Err(
            "대화가 너무 길거나 올바르지 않습니다. 새 대화를 시작하거나 내용을 줄여 주세요.".into(),
        );
    }
    Ok(())
}
fn request_body(provider: Provider, model: &str, messages: &[Message]) -> Value {
    match provider {
        Provider::Openai => {
            json!({"model": model, "input": messages, "store": false, "max_output_tokens": 4096})
        }
        Provider::Openrouter | Provider::Vercel => {
            json!({"model": model, "messages": messages, "max_tokens": 4096})
        }
    }
}
pub(crate) fn response_text(provider: Provider, value: &Value) -> Result<String, String> {
    let text = match provider {
        Provider::Openai => {
            if value["status"] != "completed" {
                return Err(
                    "응답이 완료되지 않았습니다. 요청을 줄이거나 모델을 바꿔 다시 시도하세요."
                        .into(),
                );
            }
            value["output"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|item| item["type"] == "message")
                .flat_map(|item| item["content"].as_array().into_iter().flatten())
                .filter(|part| part["type"] == "output_text")
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        }
        Provider::Openrouter | Provider::Vercel => {
            if value["choices"][0]["finish_reason"] == "length" {
                let content = value["choices"][0]["message"]["content"]
                    .as_str()
                    .unwrap_or("");
                if !content.trim().is_empty() {
                    return Ok(format!("{content}\n\n— 출력 한도에 도달해 답변이 중단되었습니다. 설정에서 출력 한도를 높일 수 있습니다."));
                }
                let reasoning = value["usage"]["completion_tokens_details"]["reasoning_tokens"]
                    .as_u64()
                    .unwrap_or(0);
                return Err(format!("추론 중 출력 한도에 도달해 답변을 만들지 못했습니다. AI 설정에서 출력 한도를 높여 주세요.\n완료 사유: length · 추론 토큰: {reasoning}"));
            }
            if value["choices"][0]["finish_reason"] != "stop" {
                return Err(
                    "응답이 완료되지 않았습니다. 요청을 줄이거나 모델을 바꿔 다시 시도하세요."
                        .into(),
                );
            }
            value["choices"][0]["message"]["content"]
                .as_str()
                .unwrap_or("")
                .to_owned()
        }
    };
    if text.trim().is_empty() {
        Err("텍스트 응답을 받지 못했습니다. 텍스트 모델인지 확인하세요.".into())
    } else {
        Ok(text)
    }
}
// Classify bounded provider metadata; never return raw provider bodies, keys or echoed prompts.
fn http_error(
    provider: Provider,
    model: &str,
    status: u16,
    request_id: Option<&str>,
    body: &Value,
) -> String {
    let details = [
        body["error"]["code"].as_str(),
        body["error"]["type"].as_str(),
        body["error"]["message"].as_str(),
        body["error"]["metadata"]["raw"].as_str(),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" ")
    .to_ascii_lowercase();
    let error_type = [
        body["error"]["type"].as_str(),
        body["error"]["code"].as_str(),
    ]
    .into_iter()
    .flatten()
    .find(|kind| {
        matches!(
            *kind,
            "quota_for_entity_exceeded"
                | "insufficient_funds"
                | "insufficient_quota"
                | "provider_error"
                | "invalid_api_key"
                | "authentication_error"
                | "model_not_found"
                | "rate_limit_exceeded"
                | "access_denied"
                | "invalid_request_error"
                | "internal_server_error"
        )
    });
    let upstream_error =
        details.contains("provider_error") || body["error"]["metadata"]["raw"].is_string();
    let message = if !upstream_error && details.contains("quota_for_entity_exceeded") {
        "Gateway가 이 키에 적용되는 사용 예산 초과를 보고했습니다. 팀·프로젝트·API 키별 예산을 확인하세요."
    } else if [
        "insufficient_quota",
        "insufficient_funds",
        "insufficient funds",
        "insufficient credits",
        "credit balance",
    ]
    .iter()
    .any(|word| details.contains(word))
    {
        if upstream_error {
            "모델 제공업체가 크레딧·할당량 오류를 반환했습니다. Gateway 잔액 부족을 뜻하는지는 확인되지 않았습니다."
        } else {
            "서버가 이 API 키의 크레딧·할당량 부족을 보고했습니다. 키가 속한 계정·팀과 결제 설정을 확인하세요."
        }
    } else if status == 402 {
        "서버가 결제·할당량 확인 단계에서 요청을 거부했습니다. HTTP 402만으로 잔액 부족을 확정할 수 없습니다."
    } else if status == 401 {
        "API 키가 거부되었습니다. 설정에서 키를 변경하세요."
    } else if status == 403 {
        "이 모델을 사용할 권한이 없습니다. 계정의 모델 접근 권한과 결제 조건을 확인하세요."
    } else if status == 429 {
        "요청 한도에 도달했습니다. 잠시 후 다시 보내세요."
    } else if ["context_length", "context window", "too many tokens"]
        .iter()
        .any(|word| details.contains(word))
    {
        "모델이 처리할 수 있는 대화 길이를 초과했습니다. 새 대화를 시작하세요."
    } else if status == 404
        || [
            "model_not_found",
            "no available provider",
            "no endpoints found",
            "model is not available",
            "model not found",
        ]
        .iter()
        .any(|word| details.contains(word))
    {
        "현재 이 모델로 연결할 수 없습니다. 설정에서 다른 모델을 선택하고 새 대화를 시작하세요."
    } else if status == 400 || status == 422 || details.contains("unsupported_parameter") {
        "모델이 요청 형식을 거부했습니다. 다른 모델로 새 대화를 시작하거나 오류 정보를 확인하세요."
    } else if status == 408 || status == 504 {
        "모델 서버의 응답 시간이 초과되었습니다. 다시 보내거나 다른 모델을 사용하세요."
    } else if status == 502 || status == 503 || status == 529 {
        "모델 서버가 일시적으로 응답하지 않습니다. 잠시 후 다시 보내거나 다른 모델로 새 대화를 시작하세요."
    } else {
        "제공업체 내부에서 요청 처리가 실패했습니다. 다시 보내거나 다른 모델로 새 대화를 시작하세요."
    };
    let name = match provider {
        Provider::Vercel => "Vercel AI Gateway",
        Provider::Openrouter => "OpenRouter",
        Provider::Openai => "OpenAI",
    };
    let mut error = format!("{message}\n{name} · {model} · HTTP {status}");
    error.push_str(&format!("\n요청 주소: {}", provider.endpoint()));
    // Only recognized machine codes are safe diagnostics. Unknown fields can echo credentials
    // or conversation text, so neither raw messages nor arbitrary codes leave the native layer.
    error.push_str(&format!("\n오류 유형: {}", error_type.unwrap_or("unknown")));
    if let Some(id) = request_id.filter(|id| {
        id.len() <= 160
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_:./".contains(&b))
    }) {
        error.push_str(&format!("\n요청 ID: {id}"));
    }
    error
}
async fn request_json(
    app: &tauri::AppHandle,
    feature: &str,
    provider: Provider,
    model: &str,
    body: &Value,
    updates: Option<tauri::ipc::Channel<StreamUpdate>>,
) -> Result<Value, String> {
    let key = tauri::async_runtime::spawn_blocking(move || read_key(provider))
        .await
        .map_err(|_| "키체인 작업을 완료하지 못했습니다.".to_string())??
        .ok_or("먼저 API 키를 등록하세요.")?;
    let mut authorization =
        reqwest::header::HeaderValue::from_bytes(&[b"Bearer ".as_slice(), key.as_slice()].concat())
            .map_err(|_| "API 키 형식을 확인하세요.".to_string())?;
    authorization.set_sensitive(true);
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|_| "AI 연결을 준비하지 못했습니다.".to_string())?;
    let mut body = body.clone();
    if updates.is_some() {
        body["stream"] = json!(true);
        if provider != Provider::Openai { body["stream_options"] = json!({"include_usage":true}); }
    }
    let ticket = crate::ai_usage::Ticket::start(app, feature, provider.account(), model)?;
    let mut response = client
        .post(provider.endpoint())
        .header(reqwest::header::AUTHORIZATION, authorization)
        .json(&body)
        .send()
        .await
        .map_err(|_| {
            "AI 서버에 연결하지 못했거나 시간이 초과되었습니다. 연결 상태를 확인하세요.".to_string()
        })?;
    let status = response.status().as_u16();
    let request_id = ["x-request-id", "x-vercel-id"]
        .iter()
        .find_map(|name| response.headers().get(*name)?.to_str().ok())
        .map(str::to_owned);
    if (200..300).contains(&status)
        && updates.is_some()
        && response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.contains("text/event-stream"))
    {
        let channel = updates.unwrap();
        let _ = channel.send(StreamUpdate {
            text: String::new(),
        });
        let mut sse = crate::ai_stream::Sse::default();
        let mut stream = crate::ai_stream::Accumulator::new(provider);
        let mut wire_bytes = 0;
        let mut last_update = Instant::now();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "답변 연결이 중단되었습니다.")?
        {
            wire_bytes += chunk.len();
            if wire_bytes > 8 * MAX_BODY {
                return Err("AI 응답이 너무 큽니다.".into());
            }
            for event in sse.push(&chunk)? {
                let changed = stream.event(&event)?;
                if changed && last_update.elapsed() >= Duration::from_millis(32) {
                    let _ = channel.send(StreamUpdate {
                        text: stream.text.clone(),
                    });
                    last_update = Instant::now();
                }
            }
        }
        for event in sse.finish()? {
            stream.event(&event)?;
        }
        let _ = channel.send(StreamUpdate {
            text: stream.text.clone(),
        });
        let value = stream.finish()?;
        ticket.finish(&crate::ai_usage::measure(&value, cached_prices(provider, model)), "completed");
        return Ok(value);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "AI 응답을 읽지 못했습니다.".to_string())?
    {
        if bytes.len() + chunk.len() > MAX_BODY {
            return Err("AI 응답이 너무 큽니다.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    if !(200..300).contains(&status) {
        let body: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        return Err(http_error(
            provider,
            &model,
            status,
            request_id.as_deref(),
            &body,
        ));
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "AI 응답 형식이 올바르지 않습니다.".to_string())?;
    ticket.finish(&crate::ai_usage::measure(&value, cached_prices(provider, model)), "completed");
    Ok(value)
}
fn add_sources(mut text: String, value: &Value, provider: Provider) -> String {
    let mut urls = vec![];
    if let Some(citations) = value["citations"].as_array() {
        for url in citations {
            if let Some(url) = url.as_str() {
                urls.push(url.to_owned());
            }
        }
    }
    let annotations: Vec<&Value> = if provider == Provider::Openai {
        value["output"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|v| v["content"].as_array().into_iter().flatten())
            .flat_map(|v| v["annotations"].as_array().into_iter().flatten())
            .collect()
    } else {
        value["choices"][0]["message"]["annotations"]
            .as_array()
            .into_iter()
            .flatten()
            .collect()
    };
    for item in annotations {
        if let Some(url) = item["url_citation"]["url"]
            .as_str()
            .or_else(|| item["url"].as_str())
        {
            urls.push(url.to_owned());
        }
    }
    urls.retain(|url| {
        url.len() < 2048
            && reqwest::Url::parse(url).is_ok_and(|u| ["https", "http"].contains(&u.scheme()))
    });
    urls.sort();
    urls.dedup();
    if !urls.is_empty() {
        text.push_str("\n\n참고한 웹 자료\n");
    }
    for (i, url) in urls.iter().take(8).enumerate() {
        text.push_str(&format!(
            "\n- [출처 {}](<{}>)",
            i + 1,
            url.replace('>', "%3E")
                .replace('<', "%3C")
                .replace('\n', "%0A")
                .replace('\r', "%0D")
        ));
    }
    text
}
async fn send(
    app: tauri::AppHandle,
    provider: Provider,
    model: String,
    messages: Vec<Message>,
    use_web: bool,
    use_files: bool,
    updates: Option<tauri::ipc::Channel<StreamUpdate>>,
) -> Result<String, String> {
    use crate::ai_tools;
    let mut settings = ai_tools::current(&app)?;
    settings.web_search &= use_web;
    settings.local_files &= use_files;
    if provider != Provider::Openai {
        let cached = MODEL_CACHE
            .get_or_init(Default::default)
            .lock()
            .ok()
            .and_then(|cache| {
                cache
                    .get(provider.account())
                    .filter(|(when, _)| when.elapsed() < Duration::from_secs(600))
                    .map(|(_, models)| models.clone())
            });
        let catalog = if let Some(models) = cached {
            Some(models)
        } else {
            ai_list_models(provider).await.ok()
        };
        if let Some(entry) = catalog
            .as_ref()
            .and_then(|rows| rows.iter().find(|entry| entry.id == model))
        {
            if let Some(limit) = entry.max_output_tokens {
                settings.max_output_tokens = settings.max_output_tokens.min(limit);
            }
            if (settings.web_search || settings.local_files) && entry.supports_tools == Some(false)
            {
                return Err("이 모델은 도구 호출을 지원하지 않습니다. 웹·파일을 끄거나 도구 지원 모델을 선택하세요.".into());
            }
        }
    }
    let main_model = model.clone();
    run_turn(
        provider,
        model,
        messages,
        settings,
        || ai_tools::current(&app),
        |provider, model, body| {
            let updates = if model == main_model {
                updates.clone()
            } else {
                None
            };
            let app = app.clone();
            async move { request_json(&app, "chat", provider, &model, &body, updates).await }
        },
    )
    .await
}
pub(crate) fn cached_prices(provider: Provider, model: &str) -> Option<(f64, f64)> {
    let cache = MODEL_CACHE.get()?.lock().ok()?;
    let (when, models) = cache.get(provider.account())?;
    if when.elapsed() >= Duration::from_secs(600) { return None; }
    let entry = models.iter().find(|m| m.id == model)?;
    Some((entry.input_price?, entry.output_price?))
}
pub(crate) async fn rewrite(app: &tauri::AppHandle, provider: Provider, model: &str, feature: &str, instruction: &str, text: &str) -> Result<(String, crate::ai_usage::Measurement), String> {
    if cached_prices(provider, model).is_none() {
        // Catalog discovery is free and bounded; missing prices never prevent processing.
        let _ = tokio::time::timeout(Duration::from_secs(2), ai_list_models(provider)).await;
    }
    let messages = vec![Message { role: "system".into(), content: instruction.into() }, Message { role: "user".into(), content: text.into() }];
    let value = request_json(app, feature, provider, model, &request_body(provider, model, &messages), None).await?;
    if provider != Provider::Openai && value["choices"][0]["finish_reason"] != "stop" { return Err("Text processing was incomplete. Used the original text.".into()); }
    Ok((response_text(provider, &value)?, crate::ai_usage::measure(&value, cached_prices(provider, model))))
}
async fn run_turn<F, Fut, C>(
    provider: Provider,
    model: String,
    messages: Vec<Message>,
    settings: crate::ai_tools::ToolSettings,
    current: C,
    request: F,
) -> Result<String, String>
where
    F: Fn(Provider, String, Value) -> Fut,
    Fut: std::future::Future<Output = Result<Value, String>>,
    C: Fn() -> Result<crate::ai_tools::ToolSettings, String>,
{
    use crate::ai_tools;
    let mut body = request_body(provider, &model, &messages);
    body[if provider == Provider::Openai {
        "max_output_tokens"
    } else {
        "max_tokens"
    }] = json!(settings.max_output_tokens);
    let definitions = ai_tools::definitions(&settings, provider != Provider::Openai);
    let mut tools = definitions.clone();
    if provider == Provider::Openai {
        tools = tools
            .into_iter()
            .map(|v| {
                let mut f = v["function"].clone();
                f["type"] = json!("function");
                f["strict"] = json!(false);
                f
            })
            .collect();
        if settings.web_search {
            tools.push(json!({"type":"web_search","search_context_size":"low"}));
        }
    }
    if !tools.is_empty() {
        body["tools"] = json!(tools);
    }
    let mut tool_count = 0;
    let mut search_count = 0;
    let mut sources = vec![];
    let mut used_files = vec![];
    for _ in 0..5 {
        // Re-check persisted permissions before sending any subsequent tool results.
        let latest = current()?;
        if (settings.web_search && !latest.web_search)
            || (settings.local_files
                && (!latest.local_files
                    || settings
                        .folders
                        .iter()
                        .any(|f| !latest.folders.iter().any(|g| g.id == f.id))))
        {
            return Err("도구 접근 설정이 바뀌어 요청을 중지했습니다. 다시 보내세요.".into());
        }
        let value = request(provider, model.clone(), body.clone()).await?;
        let calls: Vec<Value> = if provider == Provider::Openai {
            value["output"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|v| v["type"] == "function_call")
                .cloned()
                .collect()
        } else {
            value["choices"][0]["message"]["tool_calls"]
                .as_array()
                .cloned()
                .unwrap_or_default()
        };
        if calls.is_empty() {
            let mut text = add_sources(response_text(provider, &value)?, &value, provider);
            if !sources.is_empty() {
                text = add_sources(text, &json!({"citations":sources}), provider);
            }
            if !used_files.is_empty() {
                text.push_str("\n\n참고한 로컬 파일: ");
                text.push_str(&used_files.join(", "));
            }
            return Ok(text);
        }
        if calls.len() > 6 || tool_count + calls.len() > 6 {
            return Err(
                "한 질문의 도구 실행 한도(6회)에 도달했습니다. 질문 범위를 줄여 주세요.".into(),
            );
        }
        tool_count += calls.len();
        let history_key = if provider == Provider::Openai {
            "input"
        } else {
            "messages"
        };
        if provider == Provider::Openai {
            for output in value["output"].as_array().into_iter().flatten() {
                body[history_key]
                    .as_array_mut()
                    .unwrap()
                    .push(output.clone());
            }
        } else {
            body[history_key]
                .as_array_mut()
                .unwrap()
                .push(value["choices"][0]["message"].clone());
        }
        for call in calls {
            let function = if provider == Provider::Openai {
                &call
            } else {
                &call["function"]
            };
            let name = function["name"].as_str().unwrap_or("");
            let args: Value = serde_json::from_str(function["arguments"].as_str().unwrap_or("{}"))
                .map_err(|_| "모델이 올바르지 않은 도구 인자를 반환했습니다.")?;
            let allowed = definitions.iter().any(|d| d["function"]["name"] == name);
            if !allowed {
                return Err("모델이 허용하지 않은 도구를 요청했습니다.".into());
            }
            let result: Result<Value, String> = if name == "web_search" {
                let query = args["query"]
                    .as_str()
                    .filter(|q| !q.trim().is_empty() && q.len() <= 1000)
                    .ok_or("검색어가 너무 길거나 비어 있습니다.")?;
                search_count += 1;
                if search_count > 2 {
                    Err("웹 검색은 질문당 2회까지 사용할 수 있습니다.".into())
                } else {
                    let search = request(provider, "perplexity/sonar".to_string(), json!({"model":"perplexity/sonar","messages":[{"role":"user","content":query}],"max_tokens":2048})).await?;
                    for url in search["citations"].as_array().into_iter().flatten() {
                        sources.push(url.clone());
                    }
                    Ok(
                        json!({"result":add_sources(response_text(provider,&search)?,&search,provider)}),
                    )
                }
            } else {
                let fresh = current()?;
                let result = ai_tools::execute_local(&fresh, name, &args);
                if result.is_ok() && name == "read_local_file" {
                    used_files.push(
                        args["path"]
                            .as_str()
                            .unwrap_or("")
                            .replace(['\n', '\r', '`'], " "),
                    );
                }
                result
            };
            let output = result
                .unwrap_or_else(|error| json!({"error":error}))
                .to_string();
            let item = if provider == Provider::Openai {
                json!({"type":"function_call_output","call_id":call["call_id"],"output":output})
            } else {
                json!({"role":"tool","tool_call_id":call["id"],"content":output})
            };
            body[history_key].as_array_mut().unwrap().push(item);
        }
    }
    Err("도구 실행이 길어져 중지했습니다. 질문을 더 구체적으로 나누어 주세요.".into())
}

#[derive(Clone, Serialize)]
pub struct StreamUpdate {
    text: String,
}

#[tauri::command]
pub async fn ai_chat(
    app: tauri::AppHandle,
    use_web: Option<bool>,
    use_files: Option<bool>,
    on_event: tauri::ipc::Channel<StreamUpdate>,
    state: State<'_, AiRequests>,
    request_id: String,
    provider: Provider,
    model: String,
    messages: Vec<Message>,
) -> Result<String, String> {
    validate(&model, &messages)?;
    if request_id.is_empty() || request_id.len() > 100 {
        return Err("올바르지 않은 요청입니다.".into());
    }
    let rx = state.reserve(&request_id)?;
    let result = tokio::select! {
        result = tokio::time::timeout(Duration::from_secs(240), send(app, provider, model, messages, use_web.unwrap_or(false), use_files.unwrap_or(false), Some(on_event))) => result.unwrap_or_else(|_| Err("요청이 4분을 초과했습니다. 질문 범위를 줄이거나 다른 모델을 선택하세요.".into())),
        _ = rx => Err("요청을 중지했습니다. 제공업체에서 이미 처리한 사용량은 청구될 수 있습니다.".into()),
    };
    if let Ok(mut active) = state.0.lock() {
        active.remove(&request_id);
    }
    result
}
#[tauri::command]
pub fn ai_cancel(state: State<'_, AiRequests>, request_id: String) -> Result<(), String> {
    state.cancel(&request_id)
}

impl AiRequests {
    fn reserve(&self, request_id: &str) -> Result<oneshot::Receiver<()>, String> {
        let mut active = self
            .0
            .lock()
            .map_err(|_| "AI 상태를 읽지 못했습니다.".to_string())?;
        if active.contains_key(request_id) || active.len() >= 3 {
            return Err(
                "Up to three conversations can reply at once. Wait for a reply or stop one.".into(),
            );
        }
        let (tx, rx) = oneshot::channel();
        active.insert(request_id.to_owned(), tx);
        Ok(rx)
    }

    fn cancel(&self, request_id: &str) -> Result<(), String> {
        let mut active = self
            .0
            .lock()
            .map_err(|_| "AI 상태를 읽지 못했습니다.".to_string())?;
        if let Some(tx) = active.get_mut(request_id) {
            // Reserve this slot until the canceled future has actually been dropped.
            let (replacement, _) = oneshot::channel();
            let _ = std::mem::replace(tx, replacement).send(());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_registry_bounds_concurrency_and_cancels_only_target() {
        let state = AiRequests::default();
        let mut first = state.reserve("first").unwrap();
        let mut second = state.reserve("second").unwrap();
        let mut third = state.reserve("third").unwrap();
        assert!(state.reserve("first").is_err());
        assert!(state.reserve("fourth").is_err());
        state.cancel("second").unwrap();
        assert!(second.try_recv().is_ok());
        assert!(first.try_recv().is_err());
        assert!(third.try_recv().is_err());
        assert!(
            state.reserve("fourth").is_err(),
            "cancellation keeps its slot until completion"
        );
        state.0.lock().unwrap().remove("second");
        assert!(state.reserve("fourth").is_ok());
        state.cancel("missing").unwrap();
        assert!(first.try_recv().is_err());
    }

    #[test]
    fn payment_status_alone_does_not_claim_the_users_balance_is_empty() {
        let error = http_error(
            Provider::Vercel,
            "zai/glm-5.3-flash",
            402,
            Some("icn1::fixture"),
            &Value::Null,
        );
        assert!(error.contains("잔액 부족을 확정할 수 없습니다"));
        assert!(error.contains("오류 유형: unknown"));
        assert!(error.contains(Provider::Vercel.endpoint()));
        assert!(error.contains("icn1::fixture"));
    }
    #[test]
    fn gateway_budgets_and_upstream_credit_failures_have_distinct_diagnostics() {
        let budget = http_error(
            Provider::Vercel,
            "model",
            402,
            None,
            &json!({"error":{"type":"quota_for_entity_exceeded", "message":"Project budget exceeded"}}),
        );
        assert!(budget.contains("사용 예산 초과"));
        assert!(budget.contains("오류 유형: quota_for_entity_exceeded"));
        let funds = http_error(
            Provider::Vercel,
            "model",
            402,
            None,
            &json!({"error":{"type":"insufficient_funds"}}),
        );
        assert!(funds.contains("이 API 키"));
        let upstream = http_error(
            Provider::Vercel,
            "model",
            402,
            None,
            &json!({"error":{"type":"provider_error", "metadata":{"raw":"insufficient credits"}}}),
        );
        assert!(upstream.contains("모델 제공업체"));
        assert!(upstream.contains("오류 유형: provider_error"));
    }
    #[test]
    fn unknown_error_codes_and_messages_are_not_exposed() {
        let secret = "fixture-secret-never-display";
        let error = http_error(
            Provider::Vercel,
            "model",
            402,
            None,
            &json!({"error":{"type":secret,"code":secret,"message":secret}}),
        );
        assert!(error.contains("오류 유형: unknown"));
        assert!(!error.contains(secret));
    }
    #[test]
    fn failure_details_distinguish_upstream_errors_without_echoing_secrets() {
        let secret = "fixture-secret-never-display";
        let error = http_error(
            Provider::Vercel,
            "maker/model",
            500,
            Some("req-123"),
            &json!({"error":{"message":format!("insufficient credits {secret}"), "code":"provider_error"}}),
        );
        assert!(error.contains("크레딧"));
        assert!(error.contains("HTTP 500"));
        assert!(error.contains("req-123"));
        assert!(!error.contains(secret));
        assert!(
            http_error(Provider::Vercel, "maker/model", 503, None, &Value::Null)
                .contains("일시적으로")
        );
        assert!(http_error(
            Provider::Vercel,
            "maker/model",
            500,
            None,
            &json!({"error":{"message":"No available provider"}})
        )
        .contains("이 모델로 연결할 수 없습니다"));
        assert!(!http_error(
            Provider::Openai,
            "model",
            401,
            Some("bad\nheader"),
            &Value::Null
        )
        .contains("bad\nheader"));
    }
    #[test]
    fn validates_roles_and_limits() {
        let message = |role: &str, content: String| Message {
            role: role.into(),
            content,
        };
        assert!(validate("model", &[message("user", "안녕".into())]).is_ok());
        assert!(validate("model", &[message("system", "override".into())]).is_err());
        assert!(validate("model", &[message("user", "x".repeat(32_001))]).is_err());
        assert!(validate("model\n", &[message("user", "x".into())]).is_err());
    }
    #[test]
    fn openai_disables_storage_and_extracts_message_after_reasoning() {
        assert_eq!(request_body(Provider::Openai, "model", &[])["store"], false);
        let value = json!({"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"답변"}]}]});
        assert_eq!(response_text(Provider::Openai, &value).unwrap(), "답변");
        assert!(response_text(Provider::Openai, &json!({"status":"incomplete"})).is_err());
    }
    #[test]
    fn openrouter_marks_partial_text_and_rejects_missing_text() {
        assert_eq!(
            response_text(
                Provider::Openrouter,
                &json!({"choices":[{"finish_reason":"stop","message":{"content":"hello"}}]})
            )
            .unwrap(),
            "hello"
        );
        assert!(response_text(
            Provider::Openrouter,
            &json!({"choices":[{"finish_reason":"length","message":{"content":"partial"}}]})
        )
        .unwrap()
        .contains("출력 한도"));
        assert!(response_text(Provider::Openrouter, &json!({"choices":[]})).is_err());
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiModel {
    max_output_tokens: Option<u32>,
    supports_tools: Option<bool>,
    id: String,
    name: String,
    context_window: Option<u64>,
    input_price: Option<f64>,
    output_price: Option<f64>,
    pricing_variable: bool,
}
// Provider catalogs quote USD per token; the UI uses USD per million tokens.
fn million_token_price(value: &Value) -> Option<f64> {
    let price = value
        .as_f64()
        .or_else(|| value.as_str()?.parse::<f64>().ok())?
        * 1_000_000.0;
    (price.is_finite() && price >= 0.0).then_some(price)
}
fn has_text(value: &Value) -> bool {
    value
        .as_array()
        .is_some_and(|values| values.iter().any(|v| v == "text"))
}
// OpenAI's list endpoint has no modality/endpoint metadata. Keep text-family candidates
// and exclude known specialized endpoints; listing never proves inference permission.
fn openai_text_candidate(id: &str) -> bool {
    let base = id
        .strip_prefix("ft:")
        .and_then(|s| s.split(':').next())
        .unwrap_or(id);
    (base.starts_with("gpt-")
        || ["o1", "o3", "o4"]
            .iter()
            .any(|prefix| base == *prefix || base.starts_with(&format!("{prefix}-"))))
        && ![
            "audio",
            "realtime",
            "transcrib",
            "tts",
            "image",
            "search",
            "instruct",
            "chat-latest",
        ]
        .iter()
        .any(|part| base.contains(part))
}
fn parse_models(provider: Provider, value: &Value) -> Result<Vec<AiModel>, String> {
    let rows = value["data"]
        .as_array()
        .ok_or("모델 목록 형식이 올바르지 않습니다.")?;
    if rows.len() > 10_000 {
        return Err("모델 목록이 너무 큽니다.".into());
    }
    let mut models = Vec::new();
    for row in rows {
        let Some(id) = row["id"].as_str().filter(|id| {
            !id.is_empty() && id.len() <= 200 && id.bytes().all(|b| b.is_ascii_graphic())
        }) else {
            continue;
        };
        if id.ends_with(":batch") {
            continue;
        }
        let supported = match provider {
            Provider::Vercel => {
                row["type"] == "language"
                    && has_text(&row["modalities"]["input"])
                    && has_text(&row["modalities"]["output"])
            }
            Provider::Openrouter => {
                has_text(&row["architecture"]["input_modalities"])
                    && has_text(&row["architecture"]["output_modalities"])
            }
            Provider::Openai => openai_text_candidate(id),
        };
        if !supported {
            continue;
        }
        let name = row["name"]
            .as_str()
            .filter(|name| !name.trim().is_empty())
            .unwrap_or(id)
            .chars()
            .take(180)
            .collect();
        models.push(AiModel {
            max_output_tokens: row["max_tokens"]
                .as_u64()
                .or_else(|| row["top_provider"]["max_completion_tokens"].as_u64())
                .filter(|n| *n > 0)
                .and_then(|n| u32::try_from(n).ok()),
            supports_tools: row["supported_parameters"]
                .as_array()
                .map(|p| p.iter().any(|v| v == "tools")),
            id: id.to_owned(),
            name,
            context_window: row["context_window"]
                .as_u64()
                .or_else(|| row["context_length"].as_u64()),
            input_price: million_token_price(
                &row["pricing"][if provider == Provider::Openrouter {
                    "prompt"
                } else {
                    "input"
                }],
            ),
            output_price: million_token_price(
                &row["pricing"][if provider == Provider::Openrouter {
                    "completion"
                } else {
                    "output"
                }],
            ),
            pricing_variable: ["overrides", "input_tiers", "output_tiers"]
                .iter()
                .any(|field| {
                    row["pricing"][field]
                        .as_array()
                        .is_some_and(|tiers| !tiers.is_empty())
                })
                || row["pricing"]["varies_by_provider"]
                    .as_bool()
                    .unwrap_or(false),
        });
    }
    models.sort_by(|a, b| a.id.cmp(&b.id));
    models.dedup_by(|a, b| a.id == b.id);
    Ok(models)
}

#[tauri::command]
pub async fn ai_list_models(provider: Provider) -> Result<Vec<AiModel>, String> {
    let endpoint = match provider {
        Provider::Openai => "https://api.openai.com/v1/models",
        Provider::Openrouter => "https://openrouter.ai/api/v1/models",
        Provider::Vercel => "https://ai-gateway.vercel.sh/v1/models",
    };
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| "모델 목록 연결을 준비하지 못했습니다.".to_string())?;
    let mut request = client.get(endpoint);
    if provider == Provider::Openai {
        let key = cached_key(provider)?;
        let mut authorization = reqwest::header::HeaderValue::from_bytes(
            &[b"Bearer ".as_slice(), key.as_slice()].concat(),
        )
        .map_err(|_| "API 키 형식을 확인하세요.".to_string())?;
        authorization.set_sensitive(true);
        request = request.header(reqwest::header::AUTHORIZATION, authorization);
    }
    let mut response = request.send().await.map_err(|_| {
        "모델 목록을 가져오지 못했습니다. 연결을 확인하고 다시 시도하세요.".to_string()
    })?;
    if !response.status().is_success() {
        return Err(match response.status().as_u16() {
            401 | 403 => "모델 목록에 접근할 수 없습니다. API 키와 계정 권한을 확인하세요.",
            429 => "모델 목록 요청이 너무 많습니다. 잠시 후 다시 시도하세요.",
            _ => "제공업체에서 모델 목록을 가져오지 못했습니다. 다시 시도하세요.",
        }
        .into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "모델 목록을 읽지 못했습니다.".to_string())?
    {
        if bytes.len() + chunk.len() > 8 * MAX_BODY {
            return Err("모델 목록이 너무 큽니다.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "모델 목록 형식이 올바르지 않습니다.".to_string())?;
    let models = parse_models(provider, &value)?;
    if let Ok(mut cache) = MODEL_CACHE.get_or_init(Default::default).lock() {
        cache.insert(
            provider.account().to_owned(),
            (Instant::now(), models.clone()),
        );
    }
    Ok(models)
}

#[cfg(test)]
mod model_tests {
    use super::*;
    #[test]
    fn vercel_uses_gateway_key_account_and_chat_contract() {
        assert_eq!(Provider::Vercel.account(), "vercel");
        assert_eq!(
            Provider::Vercel.endpoint(),
            "https://ai-gateway.vercel.sh/v1/chat/completions"
        );
        let body = request_body(
            Provider::Vercel,
            "creator/model",
            &[Message {
                role: "user".into(),
                content: "hello".into(),
            }],
        );
        assert_eq!(body["model"], "creator/model");
        assert_eq!(body["messages"][0]["content"], "hello");
        assert_eq!(
            response_text(
                Provider::Vercel,
                &json!({"choices":[{"finish_reason":"stop","message":{"content":"hello"}}]})
            )
            .unwrap(),
            "hello"
        );
    }
    #[test]
    fn gateway_catalog_excludes_non_language_and_non_text_models() {
        let rows = json!({"data":[
            {"id":"creator/chat","name":"Chat","type":"language","modalities":{"input":["text","image"],"output":["text"]},"context_window":128000},
            {"id":"creator/embed","type":"embedding","modalities":{"input":["text"],"output":["text"]}},
            {"id":"creator/speech","type":"language","modalities":{"input":["audio"],"output":["audio"]}}
        ]});
        let models = parse_models(Provider::Vercel, &rows).unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "creator/chat");
        assert_eq!(models[0].context_window, Some(128000));
    }
    #[test]
    fn openrouter_filters_batch_and_deduplicates() {
        let mut row = json!({"id":"creator/chat","architecture":{"input_modalities":["text"],"output_modalities":["text"]}});
        let duplicate = row.clone();
        row["id"] = json!("creator/chat:batch");
        let models = parse_models(
            Provider::Openrouter,
            &json!({"data":[duplicate.clone(), duplicate, row]}),
        )
        .unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].name, "creator/chat");
        assert!(parse_models(Provider::Openrouter, &json!({"error":"failed"})).is_err());
    }
    #[test]
    fn openai_filters_specialized_models_without_hardcoding_catalog() {
        for id in ["gpt-future-mini", "o3", "ft:gpt-4.1-mini:org:custom"] {
            assert!(openai_text_candidate(id));
        }
        for id in [
            "gpt-image-1",
            "gpt-4o-realtime-preview",
            "gpt-4o-mini-tts",
            "text-embedding-3-small",
            "gpt-4o-search-preview",
        ] {
            assert!(!openai_text_candidate(id));
        }
    }
    #[test]
    fn prices_use_million_tokens_and_preserve_zero_or_unavailable() {
        assert_eq!(million_token_price(&json!("0.00000012")), Some(0.12));
        assert_eq!(million_token_price(&json!(0)), Some(0.0));
        for value in [json!(null), json!("-1"), json!("NaN"), json!("1e999")] {
            assert_eq!(million_token_price(&value), None);
        }
        let router = parse_models(Provider::Openrouter, &json!({"data":[{
            "id":"creator/chat", "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
            "pricing":{"prompt":"0.000003", "completion":"0.000015", "overrides":[{"min_prompt_tokens":200000}]}
        }]})).unwrap();
        assert_eq!(router[0].input_price, Some(3.0));
        assert!((router[0].output_price.unwrap() - 15.0).abs() < 1e-8);
        assert!(router[0].pricing_variable);
    }
    #[test]
    fn saved_key_info_never_exposes_the_secret() {
        assert!(!key_info(None).configured);
        assert_eq!(
            key_info(Some(b"short")).masked_key.as_deref(),
            Some("•••• ••••")
        );
        assert_eq!(
            key_info(Some(b"fixture-secret-1234")).masked_key.as_deref(),
            Some("•••• •••• 1234")
        );
    }
    #[test]
    #[cfg(target_os = "macos")]
    #[ignore = "Explicit Keychain roundtrip using an isolated fixture service; no user credentials"]
    fn isolated_keychain_roundtrip() {
        use security_framework::passwords::{
            delete_generic_password, generic_password, set_generic_password, PasswordOptions,
        };
        let service = format!(
            "dev.prism.test.ai.{}.{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = delete_generic_password(&self.0, "fixture");
            }
        }
        let _cleanup = Cleanup(service.clone());
        set_generic_password(&service, "fixture", b"fixture-key-1234").unwrap();
        let read = || generic_password(PasswordOptions::new_generic_password(&service, "fixture"));
        let stored = read().unwrap();
        assert_eq!(stored, b"fixture-key-1234");
        assert_eq!(
            key_info(Some(&stored)).masked_key.as_deref(),
            Some("•••• •••• 1234")
        );
        set_generic_password(&service, "fixture", b"fixture-replacement-5678").unwrap();
        assert_eq!(read().unwrap(), b"fixture-replacement-5678");
        delete_generic_password(&service, "fixture").unwrap();
        assert_eq!(read().unwrap_err().code(), -25300);
    }
    #[tokio::test]
    #[ignore = "Explicit public model discovery only; no keys or inference requests"]
    async fn public_catalogs_return_text_models() {
        for provider in [Provider::Vercel, Provider::Openrouter] {
            let models = ai_list_models(provider).await.unwrap();
            assert!(!models.is_empty());
            let priced = models
                .iter()
                .filter(|model| model.input_price.is_some() && model.output_price.is_some())
                .count();
            assert!(priced > 0);
            println!(
                "{}: {} text models, {} with input/output prices",
                provider.account(),
                models.len(),
                priced
            );
        }
    }
}

#[cfg(test)]
mod tool_loop_tests {
    use super::*;
    use crate::ai_tools::{Folder, ToolSettings};
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    fn messages() -> Vec<Message> {
        vec![Message {
            role: "user".into(),
            content: "Read my notes and find public documentation".into(),
        }]
    }
    #[tokio::test]
    async fn executes_local_and_search_calls_then_returns_grounded_answer() {
        let root = std::env::temp_dir().join(format!("prism-tool-loop-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("notes.md"), "local fixture").unwrap();
        let settings = ToolSettings {
            web_search: true,
            local_files: true,
            folders: vec![Folder {
                id: "fixture".into(),
                path: root.canonicalize().unwrap(),
            }],
            ..Default::default()
        };
        let count = Arc::new(AtomicUsize::new(0));
        let calls = count.clone();
        let answer=run_turn(Provider::Vercel,"zai/glm-5.3-flash".into(),messages(),settings.clone(),||Ok(settings.clone()),move|_,model,body|{
            let step=calls.fetch_add(1,Ordering::SeqCst);
            async move {match step {
                0=>{assert_eq!(body["max_tokens"],16384);assert_eq!(body["tools"].as_array().unwrap().len(),3);Ok(json!({"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"reasoning_content":"opaque provider state","tool_calls":[{"id":"read1","type":"function","function":{"name":"read_local_file","arguments":"{\"folder_id\":\"fixture\",\"path\":\"notes.md\"}"}},{"id":"search1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"public documentation\"}"}}]}}]}))},
                1=>{assert_eq!(model,"perplexity/sonar");assert!(!body.to_string().contains("local fixture"));Ok(json!({"choices":[{"finish_reason":"stop","message":{"content":"Search summary"}}],"citations":["https://example.com/docs"]}))},
                2=>{let stream=body["messages"].as_array().unwrap();assert_eq!(stream[1]["reasoning_content"],"opaque provider state");assert!(stream[2]["content"].as_str().unwrap().contains("local fixture"));assert!(stream[3]["content"].as_str().unwrap().contains("example.com"));Ok(json!({"choices":[{"finish_reason":"stop","message":{"content":"Grounded answer"}}]}))},
                _=>panic!("unexpected retry")
            }}
        }).await.unwrap();
        assert!(
            answer.contains("Grounded answer")
                && answer.contains("https://example.com/docs")
                && answer.contains("notes.md")
        );
        assert_eq!(count.load(Ordering::SeqCst), 3);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn rejects_unoffered_tools_without_executing_them() {
        let answer=run_turn(Provider::Vercel,"fixture".into(),messages(),ToolSettings::default(),||Ok(ToolSettings::default()),|_,_,_|async{Ok(json!({"choices":[{"message":{"tool_calls":[{"id":"bad","function":{"name":"run_shell","arguments":"{}"}}]}}]}))}).await;
        assert!(answer.unwrap_err().contains("허용하지 않은"));
    }
    #[tokio::test]
    async fn revoked_permissions_stop_before_another_provider_request() {
        let settings = ToolSettings {
            web_search: true,
            ..Default::default()
        };
        let answer = run_turn(
            Provider::Vercel,
            "fixture".into(),
            messages(),
            settings,
            || Ok(ToolSettings::default()),
            |_, _, _| async {
                panic!("permission must be checked first");
                #[allow(unreachable_code)]
                Ok(Value::Null)
            },
        )
        .await;
        assert!(answer.unwrap_err().contains("설정이 바뀌어"));
    }
    #[test]
    fn reasoning_limit_has_specific_recovery_and_partial_answers_are_retained() {
        let value = json!({"choices":[{"finish_reason":"length","message":{"content":null}}],"usage":{"completion_tokens_details":{"reasoning_tokens":4096}}});
        let error = response_text(Provider::Vercel, &value).unwrap_err();
        assert!(error.contains("추론") && error.contains("4096"));
        let value =
            json!({"choices":[{"finish_reason":"length","message":{"content":"Partial answer"}}]});
        assert!(response_text(Provider::Vercel, &value)
            .unwrap()
            .contains("Partial answer"));
    }
}
