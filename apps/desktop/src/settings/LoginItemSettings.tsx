import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { t, useLocale } from "../i18n";
import { isTauriRuntime } from "../providers/native";

type LoginItemStatus = "unsupported" | "notRegistered" | "enabled" | "requiresApproval" | "notFound";
const descriptions: Record<LoginItemStatus, string> = {
  unsupported: "Available in the installed macOS app in Applications.",
  notRegistered: "Start Prism in the background when you sign in to your Mac.",
  enabled: "Prism will start in the background when you sign in.",
  requiresApproval: "Allow Prism in System Settings → General → Login Items to finish enabling automatic startup.",
  notFound: "macOS could not find Prism's login item. Try enabling it again.",
};

export function LoginItemSettings() {
  useLocale();
  const native = isTauriRuntime();
  const [status, setStatus] = useState<LoginItemStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const operation = useRef(false);
  const revision = useRef(0);
  const mounted = useRef(false);
  const refresh = async () => {
    if (!native || operation.current) return;
    const request = ++revision.current;
    try {
      const next = await invoke<LoginItemStatus>("get_login_item_status");
      if (mounted.current && request === revision.current) { setStatus(next); setError(""); }
    } catch {
      if (mounted.current && request === revision.current) {
        setStatus(null); setError(t("Could not read login item settings."));
      }
    }
  };
  useEffect(() => {
    mounted.current = true;
    void refresh();
    const onFocus = () => void refresh();
    const onVisibility = () => { if (!document.hidden) void refresh(); };
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      mounted.current = false; ++revision.current;
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [native]);

  if (!native) return null;
  const change = async () => {
    if (operation.current || !status || status === "unsupported") return;
    operation.current = true; ++revision.current; setBusy(true); setError("");
    try {
      const next = await invoke<LoginItemStatus>("set_login_item_enabled", {
        enabled: status !== "enabled" && status !== "requiresApproval",
      });
      if (mounted.current) setStatus(next);
    } catch {
      if (mounted.current) setError(t("Could not change login item settings. Try again."));
      try {
        const actual = await invoke<LoginItemStatus>("get_login_item_status");
        if (mounted.current) setStatus(actual);
      } catch { if (mounted.current) setStatus(null); }
    } finally {
      operation.current = false;
      if (mounted.current) setBusy(false);
    }
  };
  const openSettings = async () => {
    try { await invoke("open_login_item_settings"); }
    catch { if (mounted.current) setError(t("Could not open Login Items. Open System Settings → General → Login Items.")); }
  };
  return <div className="settings-group" role="group" aria-label={t("Startup")}>
    <div className="settings-row">
      <div className="preference-copy" aria-live="polite">
        <strong>{t("Launch at login")}</strong>
        <span>{status ? t(descriptions[status]) : t("Checking login item settings…")}</span>
        {error && <span role="alert">{error}</span>}
      </div>
      <button type="button" className={`switch ${status === "enabled" ? "active" : ""}`}
        role="switch" aria-label={t("Launch at login")} aria-checked={status === "enabled"}
        disabled={busy || !status || status === "unsupported"} onClick={() => void change()}><span /></button>
    </div>
    {(status === "requiresApproval" || error) && <div className="settings-row">
      <div className="preference-actions">
        {status === "requiresApproval" && <button type="button" disabled={busy} onClick={() => void openSettings()}>{t("Open Login Items")}</button>}
        <button type="button" disabled={busy} onClick={() => void refresh()}>{t("Refresh")}</button>
      </div>
    </div>}
  </div>;
}
