import { invoke } from "@tauri-apps/api/core";
import { useEffect, useRef, useState } from "react";
import { Check, Download } from "lucide-react";
import { t } from "../i18n";

export interface LocalModel { id: string; name: string; description: string; bytes: number; path: string | null }
export interface LocalModels {
  models: LocalModel[];
  whisperPath: string | null;
  canInstallEngine: boolean;
  installingEngine: boolean;
  download: { modelId: string; downloaded: number; total: number } | null;
}
interface Props {
  modelPath: string;
  whisperPath: string;
  disabled: boolean;
  nativeRuntime: boolean;
  onSelect(model: LocalModel, path: string, whisperPath: string): Promise<void>;
}
const message = (error: unknown) => error instanceof Error ? error.message : String(error);
export function modelSize(bytes: number) { return bytes >= 1e9 ? `${(bytes / 1e9).toFixed(2)} GB` : `${Math.round(bytes / 1e6)} MB`; }
export function LocalModelPicker({ modelPath, whisperPath, disabled, nativeRuntime, onSelect }: Props) {
  const [catalog, setCatalog] = useState<LocalModels>();
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState("");
  const mounted = useRef(false);
  const working = useRef(false);
  const latest = useRef({ onSelect, disabled, nativeRuntime, modelPath, whisperPath });
  latest.current = { onSelect, disabled, nativeRuntime, modelPath, whisperPath };
  async function refresh() {
    const next = await invoke<LocalModels>("dictation_local_models", { preferredWhisperPath: latest.current.whisperPath });
    if (mounted.current) setCatalog(next);
    return next;
  }
  useEffect(() => {
    mounted.current = true;
    let timer: ReturnType<typeof setTimeout>;
    let stopped = false;
    async function poll() {
      try { await refresh(); } catch (error) { if (!stopped) setError(message(error)); }
      if (!stopped) timer = setTimeout(() => void poll(), 750);
    }
    if (nativeRuntime) void poll();
    return () => { mounted.current = false; stopped = true; clearTimeout(timer); };
  }, [nativeRuntime]);
  async function select(model: LocalModel) {
    if (working.current || disabled || !nativeRuntime || catalog?.download || catalog?.installingEngine) return;
    working.current = true; setBusy(model.id); setError(""); setNotice("");
    try {
      // The same command verifies existing files and downloads missing models.
      const path = await invoke<string>("dictation_download_model", { modelId: model.id });
      if (!mounted.current) return;
      const next = await refresh();
      if (!mounted.current || latest.current.disabled || !latest.current.nativeRuntime || latest.current.modelPath !== modelPath || latest.current.whisperPath !== whisperPath) return;
      if (!next.whisperPath) { setNotice("Model downloaded. Install the speech engine, then select the model to use it."); return; }
      await latest.current.onSelect(model, path, next.whisperPath);
    } catch (error) { if (mounted.current) setError(message(error)); }
    finally { working.current = false; if (mounted.current) { setBusy(""); void refresh().catch(() => {}); } }
  }
  async function install() {
    if (working.current || disabled || !nativeRuntime) return;
    working.current = true; setBusy("engine"); setError(""); setNotice("");
    try {
      await invoke<string>("dictation_install_whisper");
      if (mounted.current) { await refresh(); setNotice("Speech engine ready. Select a model to use it."); }
    } catch (error) { if (mounted.current) setError(message(error)); }
    finally { working.current = false; if (mounted.current) setBusy(""); }
  }
  const installing = busy === "engine" || catalog?.installingEngine;
  const locked = disabled || !nativeRuntime || !!busy || !!catalog?.download || !!installing;
  return <div className="dictation-local-catalog">
    <p className="dictation-notice">{t("Download once to transcribe on this Mac. Local speech recognition needs no API key and does not upload audio.")}</p>
    {!catalog && <p role="status">{t("Checking local models…")}</p>}
    {catalog && <>
      <div className="dictation-engine-status">
        <span>{t(catalog.whisperPath ? "Speech engine ready" : "Speech engine required")}</span>
        {!catalog.whisperPath && <>
          <p>{t(catalog.canInstallEngine ? "Install whisper.cpp with your existing Homebrew. This also installs its required dependencies." : "Install Homebrew or choose an existing whisper-cli in Advanced settings.")}</p>
          {catalog.canInstallEngine && <button type="button" className="settings-toolbar-button" disabled={locked} onClick={() => void install()}>{t(installing ? "Installing speech engine…" : "Install speech engine")}</button>}
          <button type="button" className="settings-toolbar-button" disabled={!!installing} onClick={() => void refresh().then(() => setError("")).catch(error => setError(message(error)))}>{t("Check Again")}</button>
        </>}
      </div>
      <div className="dictation-model-list" aria-label={t("Local speech models")}>
        {catalog.models.map(model => {
          const selected = model.path !== null && model.path === modelPath;
          return <button type="button" className="dictation-model" key={model.id} aria-pressed={selected} disabled={locked} onClick={() => void select(model)}>
            <span className="dictation-model-heading"><strong>{model.name}</strong>{selected ? <Check size={14} /> : !model.path && <Download size={14} />}</span>
            <span className="dictation-model-description">{t(model.description)}</span>
            <span className="dictation-model-id">{modelSize(model.bytes)} · {t(busy === model.id ? "Preparing model…" : selected ? "Selected" : model.path ? "Use model" : "Download and use")}</span>
          </button>;
        })}
      </div>
      {catalog.download && <div className="dictation-download" role="status">
        <span>{catalog.models.find(model => model.id === catalog.download!.modelId)?.name}</span>
        <progress aria-label={t("Model download progress")} value={catalog.download.downloaded} max={catalog.download.total} />
        <span>{modelSize(catalog.download.downloaded)} / {modelSize(catalog.download.total)}</span>
        <button type="button" className="settings-toolbar-button" onClick={() => void invoke("dictation_cancel_model_download", { modelId: catalog.download!.modelId }).catch(error => setError(message(error)))}>{t("Cancel download")}</button>
      </div>}
    </>}
    {notice && <p role="status">{t(notice)}</p>}
    {error && <div role="alert"><p>{t(error)}</p><button type="button" className="settings-toolbar-button" disabled={locked} onClick={() => void refresh().then(() => setError("")).catch(error => setError(message(error)))}>{t("Check Again")}</button></div>}
  </div>;
}
