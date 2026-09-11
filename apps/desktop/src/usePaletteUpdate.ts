import { useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { CommandItem } from "@prism/command-core";
import type { UpdateStatus } from "./Updates";
import { t, useLocale } from "./i18n";

export function usePaletteUpdate(enabled: boolean) {
  const locale = useLocale();
  const [status, setStatus] = useState<UpdateStatus>();
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);
  const revision = useRef(0);
  useEffect(() => {
    if (!enabled) return;
    let active = true;
    let stop: (() => void) | undefined;
    void listen<UpdateStatus>("prism:update-status", event => {
      if (active) { revision.current += 1; setStatus(event.payload); }
    }).then(async unlisten => {
      if (!active) { unlisten(); return; }
      stop = unlisten;
      const snapshot = revision.current;
      const value = await invoke<UpdateStatus>("get_update_status");
      if (active && snapshot === revision.current) setStatus(value);
    }).catch(() => { /* Settings retains the manual check and diagnostics. */ });
    return () => { active = false; stop?.(); };
  }, [enabled]);

  const item = useMemo<CommandItem | undefined>(() => {
    if (!enabled || !status?.version || !["available", "installing", "installed", "error"].includes(status.phase)) return;
    const installing = busy || status.phase === "installing";
    const title = installing ? t("Installing Prism update…")
      : status.phase === "installed" ? t("Restart Prism to update")
      : status.phase === "error" ? t("Retry Prism update") : t("Update Prism");
    return {
      id: "prism:update", providerId: "prism-update", kind: "command",
      title, subtitle: `Prism ${status.currentVersion} → ${status.version}`,
      section: t("Prism updates"), icon: "refresh", accent: "mint",
      keywords: ["update", "upgrade", "restart", "업데이트", "설치", "재시작"],
      actions: [{ id: "prism-update:run", title: installing ? t("Installing…")
        : status.phase === "installed" ? t("Restart Prism") : t("Download and install") }],
      data: { disabled: installing },
    };
  }, [enabled, status, busy, locale]);

  const run = async () => {
    if (!enabled || !status?.version || inFlight.current || !["available", "installed", "error"].includes(status.phase)) return;
    inFlight.current = true; setBusy(true);
    const snapshot = revision.current;
    try {
      const next = await invoke<UpdateStatus | null>(status.phase === "installed" ? "restart_after_update" : "install_update");
      if (next && snapshot === revision.current) setStatus(next);
    } finally { inFlight.current = false; setBusy(false); }
  };
  return { item, run };
}
