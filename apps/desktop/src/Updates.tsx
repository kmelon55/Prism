import { AnimatedDetails } from "./settings/InterfaceMotion";
import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { RefreshCw } from "lucide-react";
import { t, useLocale } from "./i18n";
import { isTauriRuntime } from "./providers/native";

type UpdateStatus = {
  currentVersion: string;
  phase: "idle" | "development" | "checking" | "current" | "available" | "installing" | "installed" | "error";
  version: string | null;
  error: string | null;
  automaticInstall: boolean;
};
const labels: Record<UpdateStatus["phase"], string> = {
  idle: "Updates are checked automatically every six hours.",
  development: "Updates are disabled in development builds.",
  checking: "Checking for updates…",
  current: "Prism is up to date.",
  available: "A new version of Prism is available.",
  installing: "Downloading and installing the update…",
  installed: "Update installed. Restart Prism when you are ready.",
  error: "Could not update Prism. Check your connection and try again.",
};
export function Updates({ compact = false }: { compact?: boolean }) {
  useLocale();
  const [status, setStatus] = useState<UpdateStatus>();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [dismissed, setDismissed] = useState<string>(() => {
    try { return sessionStorage.getItem("prism:dismissed-update") || ""; } catch { return ""; }
  });
  const native = isTauriRuntime();
  useEffect(() => {
    if (!native) return;
    let active = true;
    let stop: (() => void) | undefined;
    let revision = 0;
    void listen<UpdateStatus>("prism:update-status", event => {
      if (active) { revision += 1; setStatus(event.payload); }
    }).then(async unlisten => {
      if (!active) { unlisten(); return; }
      stop = unlisten;
      const snapshotRevision = revision;
      const initial = await invoke<UpdateStatus>("get_update_status");
      if (active && revision === snapshotRevision) setStatus(initial);
    }).catch(() => { if (active) setError(t("Could not load update status.")); });
    return () => { active = false; stop?.(); };
  }, [native]);
  if (!native) return null;
  const notification = status && (["available", "installing", "installed"].includes(status.phase) || status.phase === "error" && status.version);
  if (compact && (!notification || dismissed === `${status?.version}:${status?.phase}`)) return null;
  const disabled = busy || !status || ["checking", "installing", "development"].includes(status.phase);
  const canInstall = status?.phase === "available" || status?.phase === "error" && !!status.version;
  const action = canInstall ? "install_update"
    : status?.phase === "installed" ? "restart_after_update" : "check_for_updates";
  const label = canInstall ? "Download and install"
    : status?.phase === "installed" ? "Restart Prism" : "Check for updates";
  const run = async () => {
    setBusy(true); setError("");
    try {
      const next = await invoke<UpdateStatus | null>(action);
      if (next) setStatus(next);
    } catch { setError(t("Could not update Prism. Check your connection and try again.")); }
    finally { setBusy(false); }
  };
  const setAutomatic = async () => {
    setBusy(true); setError("");
    const enabled = !status?.automaticInstall;
    try {
      await invoke("set_automatic_updates", { enabled });
      // Preserve newer installation events that may arrive while the setting saves.
      setStatus(current => current ? { ...current, automaticInstall: enabled } : current);
    } catch { setError(t("Could not save update settings.")); }
    finally { setBusy(false); }
  };
  return (
    <div className={compact ? "prism-update-notice" : "settings-group"} role="region" aria-label={t("Prism updates")}>
      <div className="settings-row">
        <div className="preference-copy" aria-live="polite">
          <strong>Prism {status?.currentVersion}{status?.version ? ` → ${status.version}` : ""}</strong>
          <span>{status ? t(labels[status.phase]) : t("Checking for updates…")}</span>
          {error ? <span role="alert">{error}</span> : null}
          {!compact && status?.error ? <AnimatedDetails><summary>{t("Error details")}</summary><small>{t(status.error)}</small></AnimatedDetails> : null}
        </div>
        <div className="preference-actions">
          <button disabled={disabled} onClick={() => void run()}><RefreshCw size={14} />{t(label)}</button>
          {compact ? <button onClick={() => {
            const value = `${status?.version}:${status?.phase}`;
            setDismissed(value);
            try { sessionStorage.setItem("prism:dismissed-update", value); } catch { /* Memory still remembers this dismissal. */ }
          }}>{t("Later")}</button> : null}
        </div>
      </div>
      {!compact && <div className="settings-row">
        <div className="preference-copy"><strong>{t("Install updates automatically")}</strong><span>{t("Download and install new versions in the background. Changes take effect when you restart Prism.")}</span></div>
        <button className={`switch ${status?.automaticInstall ? "active" : ""}`} role="switch" aria-label={t("Install updates automatically")} aria-checked={status?.automaticInstall ?? false} disabled={disabled} onClick={() => void setAutomatic()}><span /></button>
      </div>}
    </div>
  );
}
