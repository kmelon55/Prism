import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useLocale } from "../i18n";
import { isTauriRuntime } from "../providers/native";
import { snippetCopy as copy } from "./copy";

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

  function apply(next: SnippetExpansionStatus) {
    setStatus(next);
    if (!dirty.current) setExclusions(next.excludedApps.join("\n"));
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

  async function execute(command: "configure" | "permissions", enabled = status?.enabled ?? false, excludedApps = status?.excludedApps ?? []) {
    if (!native || pending.current) return;
    pending.current = true; sequence.current++; setBusy(true); setError(false);
    try {
      const next = command === "permissions"
        ? await invoke<SnippetExpansionStatus>("snippet_expansion_request_permissions")
        : await invoke<SnippetExpansionStatus>("snippet_expansion_configure", { enabled, excludedApps });
      if (mounted.current) { if (command === "configure") dirty.current = false; apply(next); }
    } catch { if (mounted.current) setError(true); }
    finally { pending.current = false; if (mounted.current) setBusy(false); }
  }
  const unavailable = !native || !status?.supported || busy;
  if (native && status?.supported === false) {
    return <div className="snippet-expansion-settings"><p role="status">{copy("unavailable")}</p></div>;
  }
  return <div className="snippet-expansion-settings">
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{copy("title")}</strong><span>{copy("description")}</span></div>
      <button type="button" className={`switch ${status?.enabled ? "active" : ""}`} role="switch" aria-label={copy("enable")} aria-checked={status?.enabled ?? false} disabled={unavailable} onClick={() => void execute("configure", !status?.enabled)}><span /></button>
    </div>
    <p role="status">{!native || status?.supported === false ? copy("desktop") : status?.enabled ? copy(status.active ? "active" : "paused") : copy("off")}</p>
    <div className="preference-section compact">
      <div className="preference-copy">
        <span>{copy("accessibility")}: {copy(status?.accessibilityGranted ? "granted" : "required")}</span>
        <span>{copy("monitoring")}: {copy(status?.inputMonitoringGranted ? "granted" : "required")}</span>
      </div>
      <div className="preference-actions">
        <button type="button" disabled={unavailable} onClick={() => void execute("permissions")}>{copy("permissions")}</button>
        <button type="button" disabled={!native || busy} onClick={() => void refresh()}>{copy("refresh")}</button>
      </div>
    </div>
    <div className="preference-section compact">
      <div className="preference-copy"><label htmlFor="snippet-excluded-apps"><strong>{copy("exclusions")}</strong></label><span>{copy("exclusionsHint")}</span></div>
      <textarea id="snippet-excluded-apps" aria-label={copy("exclusions")} rows={3} value={exclusions} disabled={unavailable} placeholder="com.example.editor" onChange={(event) => { dirty.current = true; setExclusions(event.target.value); }} />
      <div className="preference-actions"><button type="button" disabled={unavailable} onClick={() => void execute("configure", status?.enabled, [...new Set(exclusions.split(/\r?\n/).map((value) => value.trim()).filter(Boolean))])}>{copy("saveExclusions")}</button></div>
    </div>
    <p className="preference-note">{copy("boundary")} {copy("privacy")}</p>
    {error || status?.error ? <p role="alert">{copy("failed")}</p> : null}
  </div>;
}
