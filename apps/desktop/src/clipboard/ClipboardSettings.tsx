import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Clipboard, Trash2, TriangleAlert } from "lucide-react";
import { t, useLocale } from "../i18n";
import { clearClipboardHistory, isTauriRuntime, onClipboardHistorySettingChanged, setClipboardHistoryEnabled } from "../providers/native";
import { getClipboardHistorySettings, notifyClipboardSettingsChanged, setClipboardHistoryRetention, type ClipboardRetentionDays, type ClipboardSettingsState } from "../providers/clipboard";

type PendingAction = { kind: "disable" } | { kind: "clear" } | { kind: "retention"; days: ClipboardRetentionDays };
export interface ClipboardSettingsProps {
  onChanged?: (settings: ClipboardSettingsState) => void;
}

/** Native state is authoritative; this component never restores enablement from browser preferences. */
export function ClipboardSettings({ onChanged }: ClipboardSettingsProps) {
  useLocale();
  const native = isTauriRuntime();
  const [settings, setSettings] = useState<ClipboardSettingsState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [confirmation, setConfirmation] = useState<PendingAction | null>(null);
  const [retry, setRetry] = useState<PendingAction | "enable" | null>(null);
  const dialog = useRef<HTMLDivElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    if (!confirmation) return;
    previousFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialog.current?.querySelector<HTMLButtonElement>("button")?.focus();
    return () => { requestAnimationFrame(() => { if (previousFocus.current?.isConnected) previousFocus.current.focus(); }); };
  }, [confirmation]);
  const mounted = useRef(false);
  const refreshSequence = useRef(0);
  const running = useRef(false);
  const changed = useRef(onChanged);
  changed.current = onChanged;

  async function refresh() {
    const sequence = ++refreshSequence.current;
    const next = await getClipboardHistorySettings();
    if (mounted.current && sequence === refreshSequence.current) { setSettings(next); changed.current?.(next); }
    return next;
  }
  useEffect(() => {
    mounted.current = true;
    let unlisten: (() => void) | undefined;
    if (native) {
      void refresh().catch((cause: unknown) => { if (mounted.current) setError(String(cause)); });
      void onClipboardHistorySettingChanged(() => {
        if (!running.current) void refresh().catch((cause: unknown) => { if (mounted.current) setError(String(cause)); });
      }).then((cleanup) => { if (mounted.current) unlisten = cleanup; else cleanup(); }).catch(() => undefined);
    }
    return () => { mounted.current = false; refreshSequence.current++; unlisten?.(); };
  }, [native]);

  async function execute(action: PendingAction | "enable") {
    if (running.current) return;
    running.current = true; refreshSequence.current++; setBusy(true); setError(""); setConfirmation(null); setRetry(null);
    let mutationCompleted = false;
    try {
      if (action === "enable") await setClipboardHistoryEnabled(true);
      else if (action.kind === "disable") await setClipboardHistoryEnabled(false);
      else if (action.kind === "clear") await clearClipboardHistory();
      else await setClipboardHistoryRetention(action.days);
      mutationCompleted = true;
      const next = await refresh();
      // A notification error is not a failed disk mutation and must never retry deletion.
      await notifyClipboardSettingsChanged(next).catch(() => undefined);
    } catch (cause) {
      if (mounted.current) { setError(String(cause)); setRetry(mutationCompleted ? null : action); }
      await refresh().catch(() => undefined);
    } finally {
      running.current = false;
      if (mounted.current) setBusy(false);
    }
  }
  const unavailable = !native || !settings || busy;
  const errorMessage = error || settings?.persistenceError;
  return <>
    <div className="preference-section compact">
      <div className="preference-copy">
        <strong>{t("Clipboard history")}</strong>
        <span>{t("Off by default. After you enable history, copied text, supported images, and local file references are saved on this device across restarts.")}</span>
      </div>
      <button className={`switch ${settings?.enabled ? "active" : ""}`} role="switch" aria-label={t("Enable clipboard history")} aria-checked={settings?.enabled ?? false} disabled={unavailable} onClick={() => settings?.enabled ? setConfirmation({ kind: "disable" }) : void execute("enable")}><span /></button>
    </div>
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{t("Keep history for")}</strong><span>{t("Pinned entries stay until deleted. Up to 1,000 entries and 128 MB total: text 128 KB, images 8 MB, and 64 file references per entry.")}</span></div>
      <select aria-label={t("Keep history for")} value={settings?.retentionDays ?? 30} disabled={unavailable} onChange={(event) => {
        const days = Number(event.target.value) as ClipboardRetentionDays;
        if (settings && days < settings.retentionDays) setConfirmation({ kind: "retention", days });
        else void execute({ kind: "retention", days });
      }}>
        <option value={1}>{t("1 day")}</option><option value={7}>{t("1 week")}</option><option value={30}>{t("1 month")}</option><option value={90}>{t("3 months")}</option>
      </select>
    </div>
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{t("Clear stored history")}</strong><span>{t("Clear and disable both delete all saved entries, including pins. Your current system clipboard is unchanged.")}</span>
        {settings ? <span>{t("{0} entries · {1} pinned", { 0: settings.entryCount, 1: settings.pinnedCount })}</span> : null}
      </div>
      <div className="preference-actions"><button disabled={unavailable} onClick={() => setConfirmation({ kind: "clear" })}><Trash2 size={14} />{t("Clear history")}</button></div>
    </div>
    {confirmation ? <div className="preference-alert" ref={dialog} onKeyDown={(event) => {
      if (event.nativeEvent.isComposing || event.keyCode === 229) return;
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); if (!event.repeat) setConfirmation(null); }
      if (event.key === "Tab") {
        const buttons = [...dialog.current!.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
        if (event.shiftKey && document.activeElement === buttons[0]) { event.preventDefault(); buttons.at(-1)?.focus(); }
        else if (!event.shiftKey && document.activeElement === buttons.at(-1)) { event.preventDefault(); buttons[0]?.focus(); }
      }
    }} role="alertdialog" aria-label={t("Confirm clipboard history change")} aria-describedby="clipboard-confirm-description">
      <div><p id="clipboard-confirm-description">{t(confirmation.kind === "disable" ? "Disable history and permanently delete all entries, including pins?" : confirmation.kind === "clear" ? "Permanently delete all clipboard entries, including pins? History will stay enabled if it is on." : "Shorten retention and permanently delete expired entries? Pinned entries will be kept.")}</p>
        <div className="preference-actions"><button disabled={busy} onClick={() => setConfirmation(null)}>{t("Cancel")}</button><button disabled={busy} onClick={() => void execute(confirmation)}>{t("Confirm")}</button></div>
      </div>
    </div> : null}
    {errorMessage ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(errorMessage)}</span>
      <button disabled={busy} onClick={() => {
        if (retry) { if (retry === "enable") void execute(retry); else setConfirmation(retry); }
        else void refresh().then(() => setError("")).catch((cause: unknown) => setError(String(cause)));
      }}>{t("Retry")}</button></div> : null}
    {settings?.captureNotice ? <div className="preference-alert" role="status"><TriangleAlert size={15} /><span>{t(settings.captureNotice)}</span></div> : null}
    <div className="preference-note"><Clipboard size={17} /><div><strong>{t("Private by design")}</strong><span>{t("Stored locally without a network connection. Private, concealed, and transient macOS items and obvious text credentials are skipped. Unmarked sensitive content may still be saved. File contents are never read or stored.")}</span>
      <span>{t("macOS supports PNG, JPEG, WebP, TIFF, and local file references. TIFF is saved as PNG. Images are limited to 8,192 pixels per side and 16 megapixels. HEIC, GIF, HTML-only, and mixed items are skipped.")}</span>
      {!native ? <span>{t("Clipboard history is available in the desktop app.")}</span> : null}
      {settings?.pinnedCount === settings?.capacity && settings ? <span>{t("All history slots are pinned. Unpin or delete an entry to capture new content.")}</span> : null}
    </div></div>
  </>;
}
