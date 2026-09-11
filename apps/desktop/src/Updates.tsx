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
  const [dismissed, setDismissed] = useState<string>();
  const native = isTauriRuntime();
  useEffect(() => {
    if (!native) return;
    let active = true;
    let stop: (() => void) | undefined;
    void listen<UpdateStatus>("prism:update-status", event => {
      if (active) setStatus(event.payload);
    }).then(async unlisten => {
      if (!active) { unlisten(); return; }
      stop = unlisten;
      const initial = await invoke<UpdateStatus>("get_update_status");
      if (active) setStatus(initial);
    }).catch(() => { if (active) setError(t("Could not load update status.")); });
    return () => { active = false; stop?.(); };
  }, [native]);
  if (!native) return null;
  const notification = status && ["available", "installing", "installed"].includes(status.phase);
  if (compact && (!notification || dismissed === `${status?.version}:${status?.phase}`)) return null;
  const disabled = busy || !status || ["checking", "installing", "development"].includes(status.phase);
  const action = status?.phase === "available" ? "install_update"
    : status?.phase === "installed" ? "restart_after_update" : "check_for_updates";
  const label = status?.phase === "available" ? "Download and install"
    : status?.phase === "installed" ? "Restart Prism" : "Check for updates";
  const run = async () => {
    setBusy(true); setError("");
    try {
      const next = await invoke<UpdateStatus | null>(action);
      if (next) setStatus(next);
    } catch { setError(t("Could not update Prism. Check your connection and try again.")); }
    finally { setBusy(false); }
  };
  return (
    <div className={compact ? "prism-update-notice" : "settings-group"} role="region" aria-label={t("Prism updates")}>
      <div className="settings-row">
        <div className="preference-copy" aria-live="polite">
          <strong>Prism {status?.currentVersion}{status?.version ? ` → ${status.version}` : ""}</strong>
          <span>{status ? t(labels[status.phase]) : t("Checking for updates…")}</span>
          {error ? <span role="alert">{error}</span> : null}
          {!compact && status?.error ? <AnimatedDetails><summary>{t("Error details")}</summary><small>{status.error}</small></AnimatedDetails> : null}
        </div>
        <div className="preference-actions">
          <button disabled={disabled} onClick={() => void run()}><RefreshCw size={14} />{t(label)}</button>
          {compact ? <button onClick={() => setDismissed(`${status?.version}:${status?.phase}`)}>{t("Later")}</button> : null}
        </div>
      </div>
    </div>
  );
}
