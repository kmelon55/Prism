import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Check } from "lucide-react";
import { t } from "../i18n";
import { notifyAiSettingsChanged, watchAiSettings, type AiKeyInfo } from "../providers/ai";

// Mount with key={provider}: late reads/writes from the previous provider cannot
// replace this provider's status, and secrets never survive a provider switch.
export function DictationApiKey({ provider, nativeRuntime, disabled, onConfigured }: {
  provider: string; nativeRuntime: boolean; disabled: boolean; onConfigured(value: boolean): void;
}) {
  const [info, setInfo] = useState<AiKeyInfo>();
  const [key, setKey] = useState("");
  const [editing, setEditing] = useState(false);
  const [checking, setChecking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const revision = useRef(0);
  const mounted = useRef(false);
  const mutation = useRef(false);
  const shared = provider === "openai" || provider === "vercel";
  const unavailable = disabled || busy;

  async function refresh() {
    if (!nativeRuntime || mutation.current) return;
    const request = ++revision.current;
    setChecking(true); setError("");
    try {
      const next = await invoke<AiKeyInfo>("dictation_key_info", { provider });
      if (!next || typeof next.configured !== "boolean") throw new Error(t("키 저장 상태를 확인하지 못했습니다."));
      if (mounted.current && request === revision.current) setInfo(next);
    } catch (error) {
      if (mounted.current && request === revision.current) setError(String(error));
    } finally {
      if (mounted.current && request === revision.current) setChecking(false);
    }
  }
  useEffect(() => {
    mounted.current = true;
    void refresh();
    const stop = watchAiSettings(() => void refresh());
    return () => { mounted.current = false; revision.current++; stop(); };
  }, [provider, nativeRuntime]);
  useEffect(() => { onConfigured(info?.configured === true); }, [info, onConfigured]);

  async function update(remove = false) {
    if (unavailable || mutation.current || (!remove && !key.trim())) return;
    mutation.current = true; revision.current++;
    setBusy(true); setChecking(false); setError(""); setNotice("");
    try {
      let next: AiKeyInfo;
      if (remove) {
        await invoke("dictation_delete_key", { provider });
        next = { configured: false, maskedKey: null };
      } else {
        next = await invoke<AiKeyInfo>("dictation_save_key", { provider, key });
        if (!next?.configured) throw new Error(t("키 저장 상태를 확인하지 못했습니다."));
      }
      if (mounted.current) {
        setInfo(next); setKey(""); setEditing(false); setConfirmDelete(false);
        setNotice(t(remove ? "키를 삭제했습니다." : "키를 저장했습니다."));
      }
      notifyAiSettingsChanged();
    } catch (error) {
      if (mounted.current) setError(String(error));
    } finally {
      mutation.current = false;
      if (mounted.current) setBusy(false);
    }
  }
  async function unlock() {
    if (unavailable || mutation.current) return;
    mutation.current = true; revision.current++;
    setBusy(true); setChecking(false); setError(""); setNotice("");
    try {
      const next = await invoke<AiKeyInfo>("dictation_unlock_key", { provider });
      if (mounted.current) setInfo(next);
      notifyAiSettingsChanged();
    } catch (error) {
      if (mounted.current) setError(String(error));
    } finally {
      mutation.current = false;
      if (mounted.current) setBusy(false);
    }
  }
  return <div role="group" aria-label={t("API key")}>
    <div className="settings-row"><div className="preference-copy"><strong>{t("API key")}</strong><span>{shared ? t("AI 설정에 저장한 키를 함께 사용합니다.") : t("API 키는 macOS 키체인에 저장합니다.")}</span></div></div>
    {info?.configured && <div className="dictation-saved-key">
      <Check size={15} aria-hidden="true" /><strong>{t("키 저장됨")}</strong>
      <code aria-label={t("저장된 API 키")}>{info.maskedKey || "•••• ••••"}</code>
      {!info.unlocked && <button className="settings-toolbar-button" disabled={unavailable} onClick={() => void unlock()}>{t("Allow key use")}</button>}
      <button className="settings-toolbar-button" disabled={unavailable} onClick={() => { setEditing(true); setConfirmDelete(false); setNotice(""); }}>{t("변경")}</button>
      <button className="settings-toolbar-button" disabled={unavailable} onClick={() => { if (!confirmDelete) setConfirmDelete(true); else void update(true); }}>{confirmDelete ? t("삭제 확인") : t("키 삭제")}</button>
    </div>}
    {info?.configured && !info.unlocked && <p className="dictation-notice">{t("In the macOS password dialog, choose Always Allow to remember access when restarting Prism. An update may require approval again.")}</p>}
    {(!info?.configured || editing || key.length > 0) && <form className="dictation-key-row" onSubmit={event => { event.preventDefault(); void update(); }}>
      <input type="password" autoComplete="off" spellCheck={false} maxLength={4096} aria-label={t("API key")} placeholder={info?.configured ? t("새 API 키") : t("API key")} disabled={unavailable} autoFocus={editing} value={key} onChange={event => setKey(event.target.value)} />
      <button type="submit" className="settings-toolbar-button" disabled={unavailable || !key.trim()}>{busy ? t("저장 중…") : t("Save key")}</button>
      {editing && <button type="button" className="settings-toolbar-button" disabled={busy} onClick={() => { setEditing(false); setKey(""); }}>{t("Cancel")}</button>}
    </form>}
    {checking && !info && <p className="dictation-notice" role="status">{t("확인 중…")}</p>}
    {info && !info.configured && <p className="dictation-notice">{t("저장된 키 없음")}</p>}
    {confirmDelete && <p className="dictation-notice">{shared ? t("이 키를 삭제하면 AI 채팅에서도 사용할 수 없습니다.") : t("저장된 제공자 키를 삭제합니다.")} <button className="settings-toolbar-button" disabled={busy} onClick={() => setConfirmDelete(false)}>{t("Cancel")}</button></p>}
    {notice && <p className="dictation-notice" role="status">{notice}</p>}
    {error && <p className="dictation-notice" role="alert">{t(error)} <button className="settings-toolbar-button" disabled={checking || unavailable} onClick={() => void refresh()}>{t("다시 확인")}</button></p>}
  </div>;
}
