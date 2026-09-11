import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { t, useLocale } from "../i18n";
import { isTauriRuntime } from "../providers/native";
import { snippetCopy as copy } from "./copy";
import { useAutoSave } from "../settings/useAutoSave";

export interface SnippetExpansionStatus {
  enabled: boolean;
  supported: boolean;
  active: boolean;
  accessibilityGranted: boolean;
  inputMonitoringGranted: boolean;
  excludedApps: string[];
  registeredCount: number;
  error: string | null;
}

/** Settings are native-owned; browser storage can never opt the user into monitoring. */
export function SnippetExpansionSettings() {
  useLocale();
  const native = isTauriRuntime();
  const [status, setStatus] = useState<SnippetExpansionStatus | null>(null);
  const [exclusions, setExclusions] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const mounted = useRef(false);
  const pending = useRef(false);
  const sequence = useRef(0);
  const dirty = useRef(false);
  const exclusionDraft = useRef("");
  const autoSave = useAutoSave<{ text: string; enabled: boolean }>(async ({ text, enabled }) => {
    sequence.current++;
    pending.current = true;
    const excludedApps = [...new Set(text.split(/\r?\n/).map(value => value.trim()).filter(Boolean))];
    try {
      const next = await invoke<SnippetExpansionStatus>("snippet_expansion_configure", { enabled, excludedApps });
      if (mounted.current) {
        if (exclusionDraft.current === text) dirty.current = false;
        setStatus(next);
      }
    } finally { pending.current = false; }
  });

  function apply(next: SnippetExpansionStatus) {
    setStatus(next);
    if (!dirty.current) { exclusionDraft.current = next.excludedApps.join("\n"); setExclusions(exclusionDraft.current); }
  }
  async function refresh() {
    if (!native || pending.current) return;
    const request = ++sequence.current;
    try {
      const next = await invoke<SnippetExpansionStatus>("snippet_expansion_status");
      if (mounted.current && sequence.current === request) { apply(next); setError(false); }
    } catch { if (mounted.current && sequence.current === request) setError(true); }
  }
  useEffect(() => {
    mounted.current = true;
    let unlisten: (() => void) | undefined;
    let disposed = false;
    void refresh();
    if (native) void listen("prism:snippet-expansion-changed", () => void refresh()).then((cleanup) => {
      if (!disposed) unlisten = cleanup; else cleanup();
    }).catch(() => undefined);
    const onFocus = () => void refresh();
    window.addEventListener("focus", onFocus);
    const timer = native ? window.setInterval(onFocus, 2000) : undefined;
    return () => { disposed = true; mounted.current = false; sequence.current++; unlisten?.(); window.removeEventListener("focus", onFocus); window.clearInterval(timer); };
  }, [native]);

  async function execute(command: "configure" | "permissions", enabled = status?.enabled ?? false) {
    if (!native || pending.current) return;
    if (command === "configure") {
      setError(false);
      autoSave.schedule({ text: exclusionDraft.current, enabled }, 0);
      await autoSave.flush();
      return;
    }
    pending.current = true; sequence.current++; setBusy(true); setError(false);
    try {
      const next = await invoke<SnippetExpansionStatus>("snippet_expansion_request_permissions");
      if (mounted.current) apply(next);
    } catch { if (mounted.current) setError(true); }
    finally { pending.current = false; if (mounted.current) setBusy(false); }
  }
  const unavailable = !native || !status?.supported || busy;
  const saving = autoSave.status === "pending" || autoSave.status === "saving";
  if (native && status?.supported === false) {
    return <div className="snippet-expansion-settings"><p role="status">{copy("unavailable")}</p></div>;
  }
  return <div className="snippet-expansion-settings">
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{copy("title")}</strong><span>{copy("description")}</span></div>
      <button type="button" className={`switch ${status?.enabled ? "active" : ""}`} role="switch" aria-label={copy("enable")} aria-checked={status?.enabled ?? false} disabled={unavailable || saving} onClick={() => void execute("configure", !status?.enabled)}><span /></button>
    </div>
    <p role="status">{!native || status?.supported === false ? copy("desktop") : status?.enabled ? copy(status.active ? "active" : "paused") : copy("off")}</p>
    <div className="preference-section compact">
      <div className="preference-copy">
        <span>{copy("accessibility")}: {copy(status?.accessibilityGranted ? "granted" : "required")}</span>
        <span>{copy("monitoring")}: {copy(status?.inputMonitoringGranted ? "granted" : "required")}</span>
      </div>
      <div className="preference-actions">
        <button type="button" disabled={unavailable || saving} onClick={() => void execute("permissions")}>{copy("permissions")}</button>
        <button type="button" disabled={!native || busy} onClick={() => void refresh()}>{copy("refresh")}</button>
      </div>
    </div>
    <div className="preference-section compact">
      <div className="preference-copy"><label htmlFor="snippet-excluded-apps"><strong>{copy("exclusions")}</strong></label><span>{copy("exclusionsHint")}</span></div>
      <textarea onBlur={() => { void autoSave.flush(); }} id="snippet-excluded-apps" aria-label={copy("exclusions")} rows={3} value={exclusions} disabled={unavailable} placeholder="com.example.editor" onChange={(event) => { dirty.current = true; exclusionDraft.current = event.target.value; setExclusions(event.target.value); autoSave.schedule({ text: event.target.value, enabled: status?.enabled ?? false }); }} />
      <span role="status">{t(saving ? "Saving…" : autoSave.status === "error" ? "Settings could not be saved." : "Changes are saved automatically.")}</span>
      {autoSave.status === "error" && <button type="button" disabled={unavailable} onClick={autoSave.retry}>{t("Retry")}</button>}
    </div>
    <p className="preference-note">{copy("boundary")} {copy("privacy")}</p>
    {error || status?.error || autoSave.error ? <p role="alert">{copy("failed")}</p> : null}
  </div>;
}
