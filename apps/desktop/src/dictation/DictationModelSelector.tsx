import { useEffect, useRef, useState } from "react";
import { ChevronDown, X } from "lucide-react";
import { t } from "../i18n";
import { providers, type DictationSettings, type DictationProvider } from "./api";
import { DictationModelPicker } from "./DictationModelPicker";
interface Props { settings: DictationSettings; disabled: boolean; nativeRuntime: boolean; configured: boolean; keyEpoch: number; onProvider(provider: DictationProvider): void; onSelect(model: string): Promise<void> }
export function DictationModelSelector({ settings, disabled, nativeRuntime, configured, keyEpoch, onProvider, onSelect }: Props) {
  const [open, setOpen] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => setError(""), [settings.provider]);
  const root = useRef<HTMLElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const close = () => { setOpen(false); requestAnimationFrame(() => trigger.current?.focus()); };
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener("pointerdown", outside);
    const frame = requestAnimationFrame(() => root.current?.querySelector<HTMLInputElement>('input[type="search"]')?.focus());
    return () => { document.removeEventListener("pointerdown", outside); cancelAnimationFrame(frame); };
  }, [open]);
  const provider = providers.find(provider => provider.id === settings.provider)!;
  const label = settings.provider === "local" ? settings.modelPath.split("/").pop() || t("로컬 모델 파일") : settings.provider === "xai" ? "Grok STT" : settings.model || t("모델을 선택하세요");
  return <section ref={root} className="ai-settings ai-current-model dictation-current-model" aria-label={t("현재 받아쓰기 모델")}>
    <div className="ai-current-model-copy"><span className="ai-eyebrow">{t("현재 모델")}</span><strong>{label}</strong><small>{provider.name}</small></div>
    <button ref={trigger} className="ai-settings-model-trigger" aria-label={t("받아쓰기 모델 변경")} aria-haspopup="dialog" aria-expanded={open} disabled={disabled} onClick={() => setOpen(value => !value)}>{t("모델 변경")}<ChevronDown size={14} /></button>
    {open && <section className="ai-model-settings ai-settings-model-popover dictation-selector-popover" role="dialog" aria-label={t("받아쓰기 모델 선택")} onKeyDown={event => {
      if (event.nativeEvent.isComposing) return;
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); }
      if (["ArrowDown", "ArrowUp"].includes(event.key)) {
        const rows = [...root.current!.querySelectorAll<HTMLButtonElement>(".dictation-model:not(:disabled)")];
        if (!rows.length) return;
        event.preventDefault(); const index = rows.indexOf(document.activeElement as HTMLButtonElement);
        rows[(index + (event.key === "ArrowDown" ? 1 : index < 0 ? 0 : -1) + rows.length) % rows.length]?.focus();
      }
    }} onBlur={event => { if (event.relatedTarget && !root.current?.contains(event.relatedTarget as Node)) setOpen(false); }}>
      <div className="ai-section-heading"><h3>{t("STT 모델")}</h3><button aria-label={t("모델 선택 닫기")} onClick={close}><X size={15} /></button></div>
      <div className="ai-picker-providers" role="group" aria-label={t("STT 제공자")}>{providers.map(provider => <button key={provider.id} disabled={disabled} aria-pressed={provider.id === settings.provider} onClick={() => onProvider(provider.id)}>{provider.id === "vercel" ? "Vercel" : provider.name}</button>)}</div>
      {error && <p role="alert" className="ai-settings-error">{error}</p>}
      {settings.provider === "local" ? <p className="ai-settings-note">{t("아래에서 whisper.cpp와 로컬 모델 파일을 선택하세요.")}</p> : <DictationModelPicker provider={settings.provider} baseURL={settings.baseURL} model={settings.model} configured={configured} keyEpoch={keyEpoch} nativeRuntime={nativeRuntime} disabled={disabled} onSelect={model => { setError(""); void onSelect(model).then(close).catch(error => setError(error instanceof Error ? error.message : String(error))); }} />}
    </section>}
  </section>;
}
