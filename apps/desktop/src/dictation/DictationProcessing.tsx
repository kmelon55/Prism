import type { ReactNode } from "react";
import { Check, Sparkles, WandSparkles } from "lucide-react";
import { AiModelPicker } from "../AiModelPicker";
import { t } from "../i18n";
import { aiProviders } from "../providers/ai";
import type { DictationSettings } from "./api";
import { cleanupInstruction, promptInstruction, enhancementEnabled, toggleEnhancement } from "./processing";
export function DictationProcessing({ settings, disabled, nativeRuntime, onChange, flush, promptShortcut, onAiSettings }: {
  settings: DictationSettings; disabled: boolean; nativeRuntime: boolean; onChange(settings: DictationSettings, delay?: number): void; flush(): Promise<boolean>; promptShortcut?: ReactNode; onAiSettings?(): void;
}) {
  const modes = [
    { id: "cleanup", title: "Refine speech", description: "Automatically polish every dictation.", model: "cleanupModel", prompt: "cleanupInstruction", defaultPrompt: cleanupInstruction, icon: Sparkles },
    { id: "prompt", title: "Structure prompt", description: "Use a shortcut when you want a polished prompt.", model: "promptModel", prompt: "promptInstruction", defaultPrompt: promptInstruction, icon: WandSparkles },
  ] as const;
  function choose(mode: "cleanup" | "prompt") { const next = toggleEnhancement(settings.enhancementMode, mode); onChange({ ...settings, enhancementMode: next, refineText: enhancementEnabled(next, "cleanup") }); }
  return <section className="dictation-processing" aria-label={t("Dictation enhancement")}>
    <div className="dictation-processing-heading"><strong>{t("Dictation enhancement")}</strong><span>{t(settings.enhancementMode === "off" ? "Off · Original transcription" : "Enable either or both")}</span></div>
    <div className="dictation-processing-grid">{modes.map(mode => {
      const selected = enhancementEnabled(settings.enhancementMode, mode.id);
      return <div className={`dictation-processing-option${selected ? " selected" : ""}`} key={mode.id}>
        <button type="button" className="dictation-processing-toggle" role="switch" aria-label={t(mode.title)} aria-checked={selected} disabled={disabled} onClick={() => choose(mode.id)}><mode.icon size={17} /><strong>{t(mode.title)}</strong><span className="dictation-mode-indicator">{selected && <Check size={12} />}</span></button>
        <p>{t(mode.description)}</p>
        <div className="dictation-processing-model"><div className="dictation-model-caption"><span>{t("Text processing model")}</span><small>{settings[mode.model] ? aiProviders[settings[mode.model]!.provider].name : ""}</small></div><AiModelPicker purpose="dictation" selection={settings[mode.model] ?? { provider:"vercel", model:"" }} disabled={disabled} nativeRuntime={nativeRuntime} onSettings={() => onAiSettings?.()} onSelect={async model => { onChange({...settings,[mode.model]:model}); if (!await flush()) throw t("Settings could not be saved."); }} /></div>
        <label className="dictation-processing-prompt"><span>{t("Processing prompt")}</span><textarea aria-label={t(mode.id === "cleanup" ? "Speech refinement prompt" : "Prompt structuring instructions")} disabled={disabled} rows={5} placeholder={t(mode.defaultPrompt)} maxLength={2000} value={settings[mode.prompt] === mode.defaultPrompt ? t(mode.defaultPrompt) : settings[mode.prompt]} onChange={event => onChange({...settings,[mode.prompt]:event.target.value},400)} /></label>
        <button type="button" className="dictation-prompt-reset" disabled={disabled || settings[mode.prompt] === mode.defaultPrompt} onClick={() => onChange({...settings,[mode.prompt]:mode.defaultPrompt})}>{t("Reset prompt")}</button>
        {selected && mode.id === "prompt" && <div className="dictation-prompt-shortcut"><div className="dictation-command">{promptShortcut}</div><p>{t("This shortcut structures and pastes a prompt. Your usual shortcut follows speech refinement settings.")}</p></div>}
        {selected && !settings[mode.model] && <p className="dictation-processing-missing">{t("Choose a text processing model.")}</p>}
      </div>;
    })}</div>
    {settings.enhancementMode !== "off" && <p className="dictation-processing-note">{t("Only dictated text is sent to the selected provider. One extra AI request per processed result.")}</p>}
  </section>;
}
