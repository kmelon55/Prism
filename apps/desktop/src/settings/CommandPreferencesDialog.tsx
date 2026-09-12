import { useEffect, useRef, useState } from "react";
import type { CommandItem } from "@prism/command-core";
import { t } from "../i18n";
import { ShortcutCapture, useShortcutCaptureLease } from "./shortcutCapture";

export function CommandPreferencesDialog({ item, mode, alias, shortcut, nativeRuntime, recording, busy, error, onRecording, onAlias, onShortcut, onRemoveShortcut, onClose }: {
  item: CommandItem; mode: "alias" | "shortcut"; alias: string; shortcut?: string; nativeRuntime: boolean;
  recording: boolean; busy: boolean; error: string; onRecording(value: boolean): void;
  onAlias(value: string): boolean; onShortcut(value: string): Promise<void>; onRemoveShortcut(): Promise<void>; onClose(): void;
}) {
  const [draft, setDraft] = useState(alias);
  const host = useRef<HTMLElement>(null);
  const capture = useRef(new ShortcutCapture());
  const lease = useShortcutCaptureLease(nativeRuntime, recording, "settings", () => onRecording(false));
  useEffect(() => { host.current?.querySelector<HTMLElement>(mode === "alias" ? "input" : "[data-record]")?.focus(); }, [mode]);
  return <div className="panel-backdrop" onMouseDown={() => { if (!busy) onClose(); }}>
    <section className="action-panel command-preferences-dialog" ref={host} role="dialog" aria-modal="true" aria-label={t("Configure {0}", {0: item.title})}
      onMouseDown={event => event.stopPropagation()} onKeyDown={event => {
        if (event.nativeEvent.isComposing || event.keyCode === 229) return;
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); if (!busy) onClose(); }
        if (event.key === "Tab" && !recording) {
          const controls = [...event.currentTarget.querySelectorAll<HTMLElement>("input:not(:disabled),button:not(:disabled)")];
          const index = controls.indexOf(document.activeElement as HTMLElement);
          event.preventDefault(); controls[(index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length]?.focus();
        }
      }}>
      <header><strong>{item.title}</strong><button type="button" onClick={onClose} disabled={busy}>{t("Close")}</button></header>
      {mode === "alias" ? <form onSubmit={event => { event.preventDefault(); if (onAlias(draft)) onClose(); }}>
        <label>{t("Alias")}<input aria-label={t("Alias")} value={draft} maxLength={80} onChange={event => setDraft(event.target.value)} /></label>
        <button type="submit">{t("Save")}</button>
      </form> : <div className="command-preferences-hotkey">
        <button type="button" data-record aria-pressed={recording} disabled={busy || !nativeRuntime} onClick={() => onRecording(!recording)}
          onBlur={() => { capture.current.reset(); onRecording(false); }}
          onKeyUp={event => { if (recording) capture.current.keyup(event.nativeEvent); }}
          onKeyDown={event => {
            if (!recording || !lease.ready || event.repeat || event.nativeEvent.isComposing || event.keyCode === 229) return;
            event.preventDefault(); event.stopPropagation();
            if (event.key === "Escape") { onRecording(false); return; }
            const value = capture.current.keydown(event.nativeEvent);
            if (value !== undefined) void onShortcut(value);
          }}>{recording ? t("키 조합 / 보조 키 두 번…") : shortcut || t("Record Hotkey")}</button>
        {shortcut && <button type="button" disabled={busy || !nativeRuntime} onClick={() => void onRemoveShortcut()}>{t("Remove shortcut")}</button>}
        {!nativeRuntime && <p>{t("Global shortcuts are available in the desktop app.")}</p>}
      </div>}
      {(error || lease.error) && <p className="preference-alert" role="alert">{error || lease.error}</p>}
    </section>
  </div>;
}
