import { useEffect, useState } from "react";
import { t } from "../i18n";
import type { ClipboardSettingsState } from "../providers/clipboard";

export function ClipboardCaptureStatus({ settings }: { settings?: ClipboardSettingsState }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    setNow(Date.now());
    const until = settings?.pausedUntilMs ?? 0;
    if (until <= Date.now()) return;
    const timer = window.setTimeout(() => setNow(Date.now()), Math.min(2_147_483_647, until - Date.now() + 50));
    return () => window.clearTimeout(timer);
  }, [settings?.pausedUntilMs]);
  if (!settings) return null;
  return <span className="clipboard-capture-status" role="status">{
    !settings.enabled ? t("History is off") : (settings.pausedUntilMs ?? 0) > now ? t("Recording paused") : t("Recording clipboard changes")
  }</span>;
}
