import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { t } from "../i18n";
import { aiErrorText, notifyAiSettingsChanged } from "../providers/ai";

interface Connection { baseUrl: string; hasKey: boolean }
export function CompatibleApiSettings({ nativeRuntime, disabled, onConnection, onModel }: {
  nativeRuntime: boolean; disabled: boolean;
  onConnection(ready: boolean): void; onModel(id: string): Promise<void>;
}) {
  const [saved, setSaved] = useState<Connection>({ baseUrl: "", hasKey: false });
  const [baseUrl, setBaseUrl] = useState("");
  const [key, setKey] = useState("");
  const [model, setModel] = useState("");
  const [ready, setReady] = useState(!nativeRuntime);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const alive = useRef(true);
  const lock = useRef(false);
  const connection = useRef(onConnection); connection.current = onConnection;
  useEffect(() => {
    alive.current = true;
    if (nativeRuntime) void invoke<Connection>("ai_get_compatible").then(value => {
      if (!alive.current) return;
      setSaved(value); setBaseUrl(value.baseUrl); setReady(true); connection.current(Boolean(value.baseUrl));
    }).catch(error => { if (alive.current) { setError(aiErrorText(error)); setReady(true); } });
    return () => { alive.current = false; };
  }, [nativeRuntime]);
  async function save() {
    if (lock.current || !nativeRuntime || !ready || disabled) return;
    lock.current = true; setBusy(true); setError(""); setNotice("");
    try {
      const value = await invoke<Connection>("ai_save_compatible", { baseUrl: baseUrl.trim(), key: key.trim() || null });
      if (!alive.current) return;
      setSaved(value); setBaseUrl(value.baseUrl); setKey(""); connection.current(true);
      notifyAiSettingsChanged(); setNotice(t("Connection saved. Choose a model or enter its ID below."));
    } catch (error) { if (alive.current) setError(aiErrorText(error)); }
    finally { lock.current = false; if (alive.current) setBusy(false); }
  }
  async function unlock() {
    if (lock.current || !nativeRuntime || disabled) return;
    lock.current = true; setBusy(true); setError("");
    try {
      await invoke("ai_unlock_compatible");
      if (alive.current) { connection.current(true); setNotice(t("이 앱이 실행되는 동안 승인한 키를 재사용합니다.")); }
    } catch (error) { if (alive.current) setError(aiErrorText(error)); }
    finally { lock.current = false; if (alive.current) setBusy(false); }
  }
  const changed = baseUrl.trim().replace(/\/$/, "") !== saved.baseUrl.replace(/\/$/, "");
  return <div className="ai-compatible-settings">
    <form className="ai-key-form" onSubmit={event => { event.preventDefault(); void save(); }}>
      <label>{t("API base URL")}<input type="url" value={baseUrl} placeholder="http://localhost:11434/v1" aria-label={t("API base URL")}
        autoComplete="off" spellCheck={false} maxLength={2048} disabled={busy || disabled || !ready || !nativeRuntime} onChange={e => setBaseUrl(e.target.value)} /></label>
      <label>{t("API key (optional)")}<input type="password" value={key} aria-label={t("API key (optional)")}
        placeholder={saved.hasKey && !changed ? t("Leave blank to keep the saved key") : t("Leave blank for servers without authentication")}
        autoComplete="off" spellCheck={false} maxLength={4096} disabled={busy || disabled || !ready || !nativeRuntime} onChange={e => setKey(e.target.value)} /></label>
      <button type="submit" disabled={!nativeRuntime || !ready || busy || disabled || !baseUrl.trim()}>{busy ? t("저장 중…") : t("Save connection")}</button>
    </form>
    {saved.hasKey && !changed && <button type="button" disabled={busy || disabled || !nativeRuntime} onClick={() => void unlock()}>{t("키 사용 허용")}</button>}
    <p className="ai-settings-note">{t("Use the API base path, including /v1 when required. Keys stay in Keychain and are not shared between server addresses.")}</p>
    <form className="ai-key-form" onSubmit={event => { event.preventDefault(); if (!busy && !disabled && !changed && saved.baseUrl && model.trim()) void onModel(model.trim()); }}>
      <label>{t("Model ID")}<input value={model} aria-label={t("Model ID")} placeholder="model-name" autoComplete="off" spellCheck={false} maxLength={200}
        disabled={busy || disabled || !nativeRuntime} onChange={e => setModel(e.target.value)} /></label>
      <button type="submit" disabled={!nativeRuntime || busy || disabled || changed || !saved.baseUrl || !model.trim()}>{t("Use model")}</button>
    </form>
    <p className="ai-settings-note">{t("Enter a model ID directly if the server does not provide a model catalog.")}</p>
    {error && <p className="ai-settings-error" role="alert">{error}</p>}
    {notice && <p className="ai-settings-notice" role="status">{notice}</p>}
  </div>;
}
