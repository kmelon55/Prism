import { invoke } from "@tauri-apps/api/core";
import { SettingsSelect } from "../settings/SettingsSelect";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Clipboard, Trash2, TriangleAlert } from "lucide-react";
import { t, useLocale } from "../i18n";
import { clearClipboardHistory, isTauriRuntime, searchNativeApplications, type NativeApplication, onClipboardHistorySettingChanged, setClipboardHistoryEnabled } from "../providers/native";
import { getClipboardHistorySettings, notifyClipboardSettingsChanged, setClipboardHistoryRetention, type ClipboardRetentionDays, type ClipboardSettingsState } from "../providers/clipboard";

type PendingAction = { kind: "disable" } | { kind: "clear" } | { kind: "retention"; days: ClipboardRetentionDays };
type SettingsAction = PendingAction | "enable" | { kind: "primary"; action: "paste" | "copy" } | { kind: "pause"; minutes: number } | { kind: "exclude"; path: string } | { kind: "include"; id: string };
function needsConfirmation(action: SettingsAction): action is PendingAction {
  return action !== "enable" && ["disable", "clear", "retention"].includes(action.kind);
}
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
  const [retry, setRetry] = useState<SettingsAction | null>(null);
  const [appQuery, setAppQuery] = useState("");
  const [applications, setApplications] = useState<NativeApplication[]>([]);
  const [clock, setClock] = useState(Date.now());
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

  useEffect(() => {
    if (!native || !appQuery.trim()) { setApplications([]); return; }
    let active = true;
    const timer = window.setTimeout(() => void searchNativeApplications(appQuery, 12).then(results => {
      if (active) setApplications(results);
    }).catch(cause => { if (active) setError(String(cause)); }), 120);
    return () => { active = false; window.clearTimeout(timer); };
  }, [native, appQuery]);
  useEffect(() => {
    const until = settings?.pausedUntilMs ?? 0;
    setClock(Date.now());
    if (until <= Date.now()) return;
    const timer = window.setTimeout(() => { setClock(Date.now()); void refresh().catch(() => undefined); }, Math.min(2_147_483_647, until - Date.now() + 50));
    return () => window.clearTimeout(timer);
  }, [settings?.pausedUntilMs]);

  async function execute(action: SettingsAction) {
    if (running.current) return;
    running.current = true; refreshSequence.current++; setBusy(true); setError(""); setConfirmation(null); setRetry(null);
    let mutationCompleted = false;
    try {
      if (action === "enable") await setClipboardHistoryEnabled(true);
      else if (action.kind === "disable") await setClipboardHistoryEnabled(false);
      else if (action.kind === "clear") await clearClipboardHistory();
      else if (action.kind === "retention") await setClipboardHistoryRetention(action.days);
      else if (action.kind === "primary") await invoke("set_clipboard_primary_action", { action: action.action });
      else if (action.kind === "pause") await invoke("set_clipboard_capture_pause", { minutes: action.minutes });
      else if (action.kind === "exclude") { await invoke("add_clipboard_excluded_application", { path: action.path }); setAppQuery(""); }
      else await invoke("remove_clipboard_excluded_application", { id: action.id });
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
  const paused = (settings?.pausedUntilMs ?? 0) > clock;
  return <>
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{t("Return action")}</strong><span>{t("Choose what Return and double-click do. Command+Return uses the other action.")}</span></div>
      <SettingsSelect label={t("Return action")} value={settings?.primaryAction ?? "paste"} disabled={unavailable}
        onChange={action => void execute({ kind: "primary", action: action as "paste" | "copy" })}
        options={[{ value: "paste", label: t("Paste to previous app") }, { value: "copy", label: t("Copy to Clipboard") }]} />
    </div>
    <div className="preference-section compact">
      <div className="preference-copy">
        <strong>{t("Clipboard history")}</strong>
        <span>{t("Off by default. After you enable history, copied text, supported images, and local file references are saved on this device across restarts.")}</span>
      </div>
      <button className={`switch ${settings?.enabled ? "active" : ""}`} role="switch" aria-label={t("Enable clipboard history")} aria-checked={settings?.enabled ?? false} disabled={unavailable} onClick={() => settings?.enabled ? setConfirmation({ kind: "disable" }) : void execute("enable")}><span /></button>
    </div>
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{t("Capture status")}</strong>
        <span role="status">{!settings?.enabled ? t("History is off") : paused ? t("Recording paused until {0}", {0: new Date(settings!.pausedUntilMs!).toLocaleTimeString()}) : t("Recording clipboard changes")}</span>
        <span>{t("Pausing keeps saved entries. Content copied while paused is not added on resume.")}</span></div>
      <SettingsSelect label={t("Pause recording")} value={paused ? "paused" : "0"} disabled={unavailable || !settings?.enabled}
        onChange={value => void execute({ kind: "pause", minutes: Number(value) })}
        options={[...(paused ? [{value: "paused", label: t("Paused"), disabled: true}] : []), {value: "0", label: t(paused ? "Resume recording" : "Recording clipboard changes")}, {value: "5", label: t("Pause for 5 minutes")}, {value: "15", label: t("Pause for 15 minutes")}, {value: "60", label: t("Pause for 1 hour")}]} />
    </div>
    <div className="settings-group" role="group" aria-label={t("Excluded applications")}>
      <h3 className="settings-group-title">{t("Excluded applications")}</h3>
      <p className="preference-note">{t("On macOS, skip clipboard changes observed while these apps are active. Existing entries are kept.")}</p>
      {(settings?.excludedApplications ?? []).map(app => <div className="settings-row" key={app.id}>
        <div className="preference-copy"><strong>{app.name}</strong><span>{app.id}</span></div>
        <button disabled={unavailable} aria-label={t("Stop excluding {0}", {0: app.name})} onClick={() => void execute({kind: "include", id: app.id})}>{t("Remove")}</button>
      </div>)}
      <input className="command-alias-input" type="search" aria-label={t("Search applications to exclude")} placeholder={t("Search applications to exclude")} value={appQuery} disabled={unavailable} onChange={event => setAppQuery(event.target.value)} />
      {applications.map(app => <div className="settings-row" key={app.id}>
        <div className="preference-copy"><strong>{app.name}</strong><span>{app.path}</span></div>
        <button disabled={unavailable} aria-label={t("Exclude {0}", {0: app.name})} onClick={() => void execute({kind: "exclude", path: app.path})}>{t("Exclude")}</button>
      </div>)}
    </div>
    <div className="preference-section compact">
      <div className="preference-copy"><strong>{t("Keep history for")}</strong><span>{t("Pinned entries stay until deleted. Up to 1,000 entries and 128 MB total: text 128 KB, images 8 MB, and 64 file references per entry.")}</span></div>
      <SettingsSelect label={t("Keep history for")} value={String(settings?.retentionDays ?? 30)} disabled={unavailable} onChange={value => {
        const days = Number(value) as ClipboardRetentionDays;
        if (settings && days < settings.retentionDays) setConfirmation({ kind: "retention", days });
        else void execute({ kind: "retention", days });
      }} options={[{value:"1",label:t("1 day")},{value:"7",label:t("1 week")},{value:"30",label:t("1 month")},{value:"90",label:t("3 months")}]} />
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
        if (retry) { if (needsConfirmation(retry)) setConfirmation(retry); else void execute(retry); }
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
