use super::ai::Provider;
use serde_json::{json, Value};
/// Incremental SSE framing operates on bytes so UTF-8 may be split at any network boundary.
#[derive(Default)]
pub struct Sse {
    buffer: Vec<u8>,
    data: Vec<u8>,
}
impl Sse {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>, String> {
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() + self.data.len() > 1_048_576 {
            return Err("AI 스트림 이벤트가 너무 큽니다.".into());
        }
        let mut events = vec![];
        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let mut line = self.buffer.drain(..=end).collect::<Vec<_>>();
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            if line.is_empty() {
                if !self.data.is_empty() {
                    events.push(
                        String::from_utf8(std::mem::take(&mut self.data))
                            .map_err(|_| "AI 스트림 인코딩이 올바르지 않습니다.")?,
                    );
                }
            } else if let Some(value) = line.strip_prefix(b"data:") {
                let value = value.strip_prefix(b" ").unwrap_or(value);
                if !self.data.is_empty() {
                    self.data.push(b'\n');
                }
                self.data.extend_from_slice(value);
            }
        }
        Ok(events)
    }
    pub fn finish(&mut self) -> Result<Vec<String>, String> {
        self.push(b"\n\n")
    }
}
pub struct Accumulator {
    provider: Provider,
    value: Value,
    pub text: String,
    terminal: bool,
}
impl Accumulator {
    pub fn new(provider: Provider) -> Self {
        Self {
            provider,
            value: json!({"choices":[{"message":{"role":"assistant","content":""},"finish_reason":null}]}),
            text: String::new(),
            terminal: false,
        }
    }
    pub fn event(&mut self, event: &str) -> Result<bool, String> {
        if event.trim() == "[DONE]" {
            return Ok(false);
        }
        let part: Value =
            serde_json::from_str(event).map_err(|_| "AI 스트림 형식이 올바르지 않습니다.")?;
        if !part["error"].is_null()
            || matches!(part["type"].as_str(), Some("error" | "response.failed"))
        {
            return Err("답변 스트림이 중단되었습니다. 다시 시도하세요.".into());
        }
        let before = self.text.len();
        if self.provider == Provider::Openai {
            match part["type"].as_str() {
                Some("response.output_text.delta") => {
                    if let Some(delta) = part["delta"].as_str() {
                        self.text.push_str(delta);
                    }
                }
                Some("response.completed" | "response.incomplete") => {
                    self.value = part["response"].clone();
                    self.terminal = true;
                }
                _ => {}
            }
        } else {
            if let Some(delta) = part["choices"][0]["delta"].as_object() {
                if let Some(content) = delta.get("content").and_then(Value::as_str) {
                    self.text.push_str(content);
                    self.value["choices"][0]["message"]["content"] = json!(self.text);
                }
                for key in ["reasoning_content", "reasoning"] {
                    if let Some(fragment) = delta.get(key).and_then(Value::as_str) {
                        let current = self.value["choices"][0]["message"][key]
                            .as_str()
                            .unwrap_or("")
                            .to_owned();
                        self.value["choices"][0]["message"][key] = json!(current + fragment);
                    }
                }
                if let Some(details) = delta.get("reasoning_details").and_then(Value::as_array) {
                    if !self.value["choices"][0]["message"]["reasoning_details"].is_array() {
                        self.value["choices"][0]["message"]["reasoning_details"] = json!([]);
                    }
                    let accumulated = self.value["choices"][0]["message"]["reasoning_details"]
                        .as_array_mut()
                        .unwrap();
                    for detail in details {
                        // Text and summary deltas belong to the same reasoning block.
                        // Encrypted blocks are opaque and must keep their original boundaries.
                        let field = match detail["type"].as_str() {
                            Some("reasoning.text") => Some("text"),
                            Some("reasoning.summary") => Some("summary"),
                            _ => None,
                        };
                        let previous = accumulated.last_mut().filter(|last| {
                            field.is_some()
                                && last["type"] == detail["type"]
                                && last["index"] == detail["index"]
                                && (last["id"].is_null()
                                    || detail["id"].is_null()
                                    || last["id"] == detail["id"])
                        });
                        if let Some(previous) = previous {
                            for key in [field.unwrap(), "signature"] {
                                if let Some(fragment) = detail[key].as_str() {
                                    let prefix = previous[key].as_str().unwrap_or("").to_owned();
                                    previous[key] = json!(prefix + fragment);
                                }
                            }
                            for key in ["id", "format"] {
                                if !detail[key].is_null() {
                                    previous[key] = detail[key].clone();
                                }
                            }
                        } else {
                            accumulated.push(detail.clone());
                        }
                    }
                }
                if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
                    if !self.value["choices"][0]["message"]["tool_calls"].is_array() {
                        self.value["choices"][0]["message"]["tool_calls"] = json!([]);
                    }
                    let accumulated = self.value["choices"][0]["message"]["tool_calls"]
                        .as_array_mut()
                        .unwrap();
                    for call in calls {
                        let index = call["index"]
                            .as_u64()
                            .ok_or("도구 호출 순서가 올바르지 않습니다.")?
                            as usize;
                        if index >= 6 {
                            return Err("도구 호출이 너무 많습니다.".into());
                        }
                        while accumulated.len() <= index {
                            accumulated.push(json!({"id":"","type":"function","function":{"name":"","arguments":""}}));
                        }
                        if let Some(id) = call["id"].as_str() {
                            accumulated[index]["id"] = json!(id);
                        }
                        for key in ["name", "arguments"] {
                            if let Some(fragment) = call["function"][key].as_str() {
                                let current = accumulated[index]["function"][key]
                                    .as_str()
                                    .unwrap_or("")
                                    .to_owned();
                                accumulated[index]["function"][key] = json!(current + fragment);
                            }
                        }
                    }
                }
            }
            if let Some(reason) = part["choices"][0]["finish_reason"].as_str() {
                self.value["choices"][0]["finish_reason"] = json!(reason);
                self.terminal = true;
            }
            for key in ["usage", "citations"] {
                if !part[key].is_null() {
                    self.value[key] = part[key].clone();
                }
            }
        }
        if self.text.len() > 1_048_576 {
            return Err("AI 응답이 너무 큽니다.".into());
        }
        Ok(self.text.len() != before)
    }
    pub fn finish(self) -> Result<Value, String> {
        if !self.terminal {
            return Err("답변 연결이 완료 전에 끊어졌습니다. 다시 시도하세요.".into());
        }
        if self.value.to_string().len() > 2_097_152 {
            return Err("AI 응답이 너무 큽니다.".into());
        }
        Ok(self.value)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_utf8_and_crlf_at_every_byte_boundary() {
        let input = "data: {\"text\":\"안녕\"}\r\n\r\n: keepalive\n\ndata: [DONE]\n\n".as_bytes();
        for split in 0..input.len() {
            let mut s = Sse::default();
            let mut events = s.push(&input[..split]).unwrap();
            events.extend(s.push(&input[split..]).unwrap());
            assert_eq!(events, vec!["{\"text\":\"안녕\"}", "[DONE]"]);
        }
    }
    #[test]
    fn rebuilds_text_and_split_tool_arguments() {
        let mut a = Accumulator::new(Provider::Vercel);
        a.event(r#"{"choices":[{"delta":{"content":"안녕","tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"id\":"}}]}}]}"#).unwrap();
        a.event(r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"one\"}"}}]},"finish_reason":"tool_calls"}]}"#).unwrap();
        let v = a.finish().unwrap();
        assert_eq!(v["choices"][0]["message"]["content"], "안녕");
        assert_eq!(
            v["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"],
            "{\"id\":\"one\"}"
        );
    }
    #[test]
    fn merges_reasoning_deltas_without_changing_encrypted_blocks() {
        let mut a = Accumulator::new(Provider::Openrouter);
        for detail in [
            json!({"type":"reasoning.text","index":0,"text":"Think ","signature":null}),
            json!({"type":"reasoning.text","index":0,"text":"carefully","signature":"signed"}),
            json!({"type":"reasoning.summary","index":1,"summary":"First "}),
            json!({"type":"reasoning.summary","index":1,"summary":"step"}),
            json!({"type":"reasoning.encrypted","index":2,"data":"opaque"}),
            json!({"type":"reasoning.encrypted","index":3,"data":"second"}),
        ] {
            a.event(&json!({"choices":[{"delta":{"reasoning_details":[detail]}}]}).to_string())
                .unwrap();
        }
        a.event(r#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
            .unwrap();
        let v = a.finish().unwrap();
        let details = v["choices"][0]["message"]["reasoning_details"]
            .as_array()
            .unwrap();
        assert_eq!(details.len(), 4);
        assert_eq!(details[0]["text"], "Think carefully");
        assert_eq!(details[0]["signature"], "signed");
        assert_eq!(details[1]["summary"], "First step");
        assert_eq!(details[2]["data"], "opaque");
        assert_eq!(details[3]["data"], "second");
    }
    #[test]
    fn requires_terminal_response_and_keeps_openai_completed_payload() {
        let mut a = Accumulator::new(Provider::Openai);
        assert!(a
            .event(r#"{"type":"response.output_text.delta","delta":"hello"}"#)
            .unwrap());
        assert!(a.finish().is_err());
        let mut a = Accumulator::new(Provider::Openai);
        a.event(r#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
            .unwrap();
        assert_eq!(a.finish().unwrap()["status"], "completed");
    }
}
