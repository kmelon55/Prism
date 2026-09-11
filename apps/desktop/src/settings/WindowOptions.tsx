import { SettingsSelect } from "./SettingsSelect";
import { AnimatedCollapse } from "./InterfaceMotion";
import { SettingsSlider } from "./SettingsSlider";
import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { RotateCcw } from "lucide-react";
import { t } from "../i18n";
import { useAutoSave } from "./useAutoSave";

export interface WindowPreferences { cycle: boolean; reverseCycle: boolean; gap: number; edgeGap: number; almostMaximize: number }
export const defaultWindowOptions: WindowPreferences = { cycle: true, reverseCycle: false, gap: 0, edgeGap: 0, almostMaximize: 90 };
export function WindowOptions({ nativeRuntime }: { nativeRuntime: boolean }) {
  const [options, setOptions] = useState(defaultWindowOptions);
  const [loaded, setLoaded] = useState(!nativeRuntime);
  const [error, setError] = useState("");
  const [previewAlmost, setPreviewAlmost] = useState(false);
  const [step, setStep] = useState(0);
  const [side, setSide] = useState<"left" | "right">("left");
  const save = useAutoSave<WindowPreferences>(async value => {
    if (nativeRuntime) await invoke("set_window_options", { options: value });
  });
  useEffect(() => {
    let cancelled = false;
    if (nativeRuntime) void invoke<WindowPreferences>("get_window_options").then(value => {
      if (!cancelled) { setOptions(value); setLoaded(true); }
    }).catch(cause => { if (!cancelled) setError(String(cause)); });
    return () => { cancelled = true; };
  }, [nativeRuntime]);
  function change(patch: Partial<WindowPreferences>) {
    const next = { ...options, ...patch };
    setOptions(next); setStep(0); setPreviewAlmost(Object.hasOwn(patch, "almostMaximize")); save.schedule(next);
  }
  const fractions = options.reverseCycle ? [1 / 2, 2 / 3, 1 / 3] : [1 / 2, 1 / 3, 2 / 3];
  const names = options.reverseCycle ? ["1/2", "2/3", "1/3"] : ["1/2", "1/3", "2/3"];
  return <section className="window-options" aria-label={t("Window behavior")}>
    <div className="window-live-preview">
      <div className="window-preview-desktop" aria-label={t("Window layout preview")}>
        <div className="window-preview-grid" />
        <div className="window-preview-tile" style={previewAlmost ? { width: `${options.almostMaximize}%`, height: `${options.almostMaximize}%`, left: `${(100-options.almostMaximize)/2}%`, top: `${(100-options.almostMaximize)/2}%` } : { width: `calc(${fractions[step] * 100}% - ${options.edgeGap / 4 + options.gap / 8}px)`, top: 8 + options.edgeGap / 4, bottom: 8 + options.edgeGap / 4, [side]: 8 + options.edgeGap / 4 }}><span>Prism</span><strong>{previewAlmost ? `${options.almostMaximize}%` : names[step]}</strong></div>
      </div>
      <div className="window-preview-controls"><span>{t("Try repeating a command")}</span><div className="preference-actions">
        {(["left", "right"] as const).map(value => <button key={value} onClick={() => { setPreviewAlmost(false); setStep(current => options.cycle && side === value ? (current + 1) % 3 : 0); setSide(value); }}><RotateCcw size={13} />{t(value === "left" ? "Left Half" : "Right Half")}</button>)}
      </div></div>
    </div>
    <fieldset disabled={!loaded} className="window-options-fields">
      <div className="settings-row"><div className="preference-copy"><strong>{t("Cycle window sizes")}</strong><span>{t("Repeat Left or Right Half to change size.")}</span></div><button className={`switch ${options.cycle ? "active" : ""}`} role="switch" aria-label={t("Cycle window sizes")} aria-checked={options.cycle} onClick={() => change({ cycle: !options.cycle })}><span /></button></div>
      <AnimatedCollapse open={options.cycle}><div className="settings-row"><strong>{t("Cycle order")}</strong><SettingsSelect label={t("Cycle order")} disabled={!loaded} value={String(options.reverseCycle)} onChange={value => change({reverseCycle:value === "true"})} options={[{value:"false",label:"1/2 → 1/3 → 2/3"},{value:"true",label:"1/2 → 2/3 → 1/3"}]} /></div></AnimatedCollapse>
      {([ ["gap", "Window gap", 0, 64], ["edgeGap", "Screen edge gap", 0, 64], ["almostMaximize", "Almost Maximize size", 50, 100] ] as const).map(([key, label, min, max]) => <div className="settings-row" key={key}><strong>{t(label)}</strong><label className="range-control"><SettingsSlider min={min} max={max} value={options[key]} aria-label={t(label)} onChange={event => change({ [key]: event.target.valueAsNumber })} /><span className="range-value">{options[key]}{key === "almostMaximize" ? "%" : "px"}</span></label></div>)}
    </fieldset>
    {!nativeRuntime && <p className="backup-hint">{t("Preview only. Window options are saved in the desktop app.")}</p>}
    {error || save.error ? <div role="alert" className="preference-alert">{t(error || save.error)}{save.error && <button onClick={save.retry}>{t("Retry")}</button>}</div> : null}
  </section>;
}
