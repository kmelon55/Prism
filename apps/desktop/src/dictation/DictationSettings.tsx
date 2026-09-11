import { DictationProcessing } from "./DictationProcessing";
import { upgradeProcessing } from "./processing";
import { AnimatedDetails } from "../settings/InterfaceMotion";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Mic, Play, RefreshCw, X } from "lucide-react";
import { currentLocale, t, useLocale } from "../i18n";
import { changeProvider, defaultSettings, dictationAction, getDictationSettings, saveDictationSettings, watchDictation, type DictationSettings as Settings, type DictationStatus } from "./api";
import "./dictation.css";
import { useAutoSave } from "../settings/useAutoSave";
import { recordingConflict, recordingDefaults } from "./recordingShortcuts";
import { DictationApiKey } from "./DictationApiKey";
import { DictationDeliverySettings } from "./DictationDeliverySettings";
import { DictationModelSelector } from "./DictationModelSelector";
import { useDictationPermissions } from "./useDictationPermissions";
import { watchAiSettings } from "../providers/ai";

function errorText(error: unknown): string { return error instanceof Error ? error.message : String(error); }
export function DictationPermissions({ nativeRuntime }: { nativeRuntime: boolean }) {
  const [status, setStatus] = useState<DictationStatus>();
  const [requesting, setRequesting] = useState(false);
  useEffect(() => { if (status?.microphone !== "notDetermined") setRequesting(false); }, [status?.microphone]);
  const [error, setError] = useState("");
  const refresh = () => { if (nativeRuntime) void dictationAction("status").then(setStatus).catch(error => setError(errorText(error))); };
  useDictationPermissions(nativeRuntime, setStatus, setError);
  if (!nativeRuntime) return <p className="dictation-notice">{t("권한은 macOS용 Prism 앱에서 확인할 수 있습니다.")}</p>;
  return <div className="settings-group dictation-permissions">
    <div className="settings-row"><div className="preference-copy"><strong>{t("Microphone")}</strong><span>{t("마이크는 받아쓰기를 시작할 때만 사용합니다.")}</span></div><span>{!status ? t("확인 중…") : status.microphone === "granted" ? t("Allowed") : t("Needs access")}</span></div>
    <div className="settings-row"><div className="preference-copy"><span>{t("권한 요청은 녹음 없이 진행됩니다. 이미 거부했다면 시스템 설정에서 허용하세요.")}</span></div><div className="preference-actions">
      {status?.microphone === "notDetermined" && <button className="settings-toolbar-button" disabled={!nativeRuntime || requesting} onClick={() => { setRequesting(true); void dictationAction("microphoneRequest").then(setStatus).catch(error => { setRequesting(false); setError(errorText(error)); }); }}>{requesting ? t("허용 대기 중…") : t("Request Access")}</button>}
      <button className="settings-toolbar-button" disabled={!nativeRuntime} onClick={() => void dictationAction("microphoneSettings").catch(error => setError(errorText(error)))}>{t("System Settings")}</button>
      <button className="settings-toolbar-button" disabled={!nativeRuntime} onClick={refresh}>{t("Check Again")}</button>
    </div></div>{error && <p role="alert">{t(error)}</p>}
  </div>;
}

export function DictationSettings({ nativeRuntime, shortcut, promptShortcut, onAiSettings, onPermissions }: { nativeRuntime: boolean; shortcut: ReactNode; promptShortcut?: ReactNode; onAiSettings?(): void; onPermissions(): void }) {
  const locale = useLocale();
  const [draft, setDraft] = useState<Settings>(defaultSettings);
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<DictationStatus>();
  const [configured, setConfigured] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [keyEpoch, setKeyEpoch] = useState(0);
  useDictationPermissions(nativeRuntime, setStatus, setError);
  useEffect(() => watchAiSettings(() => setKeyEpoch(value => value + 1)), []);
  const active = !!status && ["preparing", "recording", "transcribing", "processing", "inserting"].includes(status.phase);
  const disabled = !nativeRuntime || !ready || busy || active;
  const remote = draft.provider !== "local";
  const latestValid = useRef<Settings>(defaultSettings);
  const autoSave = useAutoSave<Settings>(saveDictationSettings);
  function updateDraft(next: Settings, delay = 0) {
    setDraft(next);
    const { defaultDelivery: _, ...bindings } = delivery(next);
    const invalid = recordingConflict(bindings) || Object.values(bindings).some(binding => binding.mode === "custom" && !binding.label);
    // Provider tabs can be browsed before choosing a model; persist other edits independently.
    const incompleteModel = next.provider === "local" ? !next.modelPath.trim() || !next.whisperPath.trim() : !next.model;
    const provider = incompleteModel
      ? { provider: latestValid.current.provider, model: latestValid.current.model, baseURL: latestValid.current.baseURL } : {};
    const value = { ...next, ...provider, ...(invalid ? delivery(latestValid.current) : {}), vocabulary: next.vocabulary.map(word => word.trim()).filter(Boolean), uiLanguage: currentLocale() };
    latestValid.current = value;
    autoSave.schedule(value, delay);
  }

  useEffect(() => {
    if (!nativeRuntime) return;
    let alive = true;
    let unlisten: (() => void) | undefined;
    void Promise.all([getDictationSettings(), dictationAction("status")]).then(([settings, state]) => {
      if (!alive) return;
      setDraft({ ...defaultSettings, ...upgradeProcessing(settings) }); latestValid.current = { ...defaultSettings, ...upgradeProcessing(settings) }; setStatus(state); setReady(true);
    }).catch(error => { if (alive) setError(errorText(error)); });
    void watchDictation(state => { if (alive) setStatus(state); }).then(stop => { if (alive) unlisten = stop; else stop(); }).catch(error => { if (alive) setError(errorText(error)); });
    return () => { alive = false; unlisten?.(); };
  }, [nativeRuntime]);
  async function perform(work: () => Promise<unknown>, message = "") {
    if (busy) return;
    setBusy(true); setError(""); setNotice("");
    try { await work(); setNotice(message); } catch (error) { setError(errorText(error)); } finally { setBusy(false); }
  }
  function changeOverlay(field: "showRecordingShortcutHints" | "showTranscriptionStatus") {
    const next = { ...draft, [field]: !(draft[field] ?? true) };
    updateDraft(next);
    if (status?.phase === "preview") void perform(async () => setStatus(await dictationAction("preview", { ...next, uiLanguage: currentLocale() })));
  }
  const delivery = (settings: Settings) => ({
    defaultDelivery: settings.defaultDelivery,
    recordingCancelShortcut: settings.recordingCancelShortcut ?? recordingDefaults.recordingCancelShortcut,
    recordingCopyShortcut: settings.recordingCopyShortcut ?? recordingDefaults.recordingCopyShortcut,
    recordingPasteShortcut: settings.recordingPasteShortcut ?? recordingDefaults.recordingPasteShortcut,
    recordingPasteAndEnterShortcut: settings.recordingPasteAndEnterShortcut ?? recordingDefaults.recordingPasteAndEnterShortcut,
  });
  async function selectModel(model: string) {
    updateDraft({ ...draft, model });
    if (!await autoSave.flush()) throw new Error(t("Settings could not be saved."));
  }
  return <div className="dictation-settings" onBlur={() => { void autoSave.flush(); }}>
    <DictationModelSelector settings={draft} disabled={disabled} nativeRuntime={nativeRuntime && ready} configured={configured} keyEpoch={keyEpoch} onProvider={provider => { if (provider === draft.provider) return; setConfigured(false); updateDraft(changeProvider(draft, provider)); setNotice(""); }} onSelect={selectModel} onChange={updateDraft} flush={autoSave.flush} />
    <DictationProcessing settings={draft} disabled={disabled} nativeRuntime={nativeRuntime} onChange={updateDraft} flush={autoSave.flush} promptShortcut={promptShortcut} onAiSettings={onAiSettings} />
    <div className="settings-group">
      <div className="settings-row"><div className="preference-copy"><strong>{t("음성 받아쓰기")}</strong><span>{t("단축키로 녹음을 시작하고, 다시 눌러 현재 앱에 입력하세요.")}</span></div><Mic size={20} /></div>
      <div className="dictation-command">{shortcut}</div>
      {nativeRuntime && status && !status.accessibility && <div className="settings-row"><div className="preference-copy"><span>{t("Ctrl 두 번과 Ctrl 단독 단축키에는 현재 실행 중인 Prism의 손쉬운 사용 권한이 필요합니다. 권한을 허용한 뒤 단축키를 다시 기록하세요.")}</span></div><button className="settings-toolbar-button" onClick={onPermissions}>{t("Open Permissions")}</button></div>}
    </div>
    <DictationDeliverySettings nativeRuntime={nativeRuntime} settings={draft} disabled={disabled} onChange={updateDraft} />
    <div className="settings-group" role="group" aria-label={t("파형 오버레이")}>
      <div className="settings-row"><div className="preference-copy"><strong>{t("파형 오버레이")}</strong><span>{t("Whisp와 같은 화면 하단 위치에 표시합니다.")}</span></div><button className="settings-toolbar-button" disabled={!nativeRuntime || !ready || active || busy} onClick={() => void perform(async () => setStatus(await dictationAction("preview", { ...draft, uiLanguage: currentLocale() })))}><Play size={14} />{t("파형 미리보기")}</button></div>
      <div className="settings-row"><div className="preference-copy"><strong>{t("녹음 중 단축키 안내")}</strong><span>{t("파형 오른쪽에 취소·붙여넣기·전송 키를 표시합니다.")}</span></div><button className={`switch ${draft.showRecordingShortcutHints ? "active" : ""}`} role="switch" aria-label={t("녹음 중 단축키 안내")} aria-checked={draft.showRecordingShortcutHints ?? true} disabled={disabled} onClick={() => changeOverlay("showRecordingShortcutHints")}><span /></button></div>
      <div className="settings-row"><div className="preference-copy"><strong>{t("전사 상태 표시")}</strong><span>{t("전사 중 파형 옆에 상태 설명을 표시합니다.")}</span></div><button className={`switch ${draft.showTranscriptionStatus ? "active" : ""}`} role="switch" aria-label={t("전사 상태 표시")} aria-checked={draft.showTranscriptionStatus ?? true} disabled={disabled} onClick={() => changeOverlay("showTranscriptionStatus")}><span /></button></div>
    </div>
    {!nativeRuntime && <p className="dictation-notice">{t("받아쓰기는 macOS용 Prism 앱에서 사용할 수 있습니다.")}</p>}
    <div className="settings-group">
      {remote ? <>
        <DictationApiKey key={draft.provider} provider={draft.provider} nativeRuntime={nativeRuntime && ready} disabled={disabled} onConfigured={setConfigured} />
        {draft.provider === "custom" && <label className="dictation-field">API Base URL<input disabled={disabled} value={draft.baseURL} placeholder="https://…/v1" onChange={event => updateDraft({ ...draft, baseURL: event.target.value }, 400)} /></label>}

      </> : null}
      <div className="dictation-options" role="group" aria-label={t("받아쓰기 언어")}>{[["auto", "Auto"], ["ko", "한국어"], ["en", "English"]].map(([value, title]) => <button className="settings-toolbar-button" disabled={disabled} key={value} aria-pressed={draft.language === value} onClick={() => updateDraft({ ...draft, language: value })}>{title}</button>)}</div>
      <AnimatedDetails className="dictation-advanced"><summary>{t("인식 힌트와 단어")}</summary>
        <label className="dictation-field">{t("인식 힌트")}<textarea rows={2} disabled={disabled} maxLength={2000} value={draft.prompt} onChange={event => updateDraft({ ...draft, prompt: event.target.value }, 400)} /></label>
        <label className="dictation-field">{t("단어 목록 · 한 줄에 하나")}<textarea rows={3} disabled={disabled} value={draft.vocabulary.join("\n")} onChange={event => updateDraft({ ...draft, vocabulary: event.target.value.split("\n") }, 400)} /></label>
      </AnimatedDetails>
      <div className="settings-row"><span role="status">{t(autoSave.status === "error" ? "Settings could not be saved." : autoSave.status === "pending" || autoSave.status === "saving" ? "Saving…" : "Changes are saved automatically.")}</span>{autoSave.status === "error" && <button className="settings-toolbar-button" onClick={autoSave.retry}>{t("Retry")}</button>}</div>
    </div>
    <div className="settings-group"><div className="settings-row"><div className="preference-copy"><strong>{t("Permissions")}</strong><span>{t("녹음에는 마이크 권한, 자동 입력에는 손쉬운 사용 권한이 필요합니다.")}</span></div><button className="settings-toolbar-button" onClick={onPermissions}>{t("Open Permissions")}</button></div>
      <div className="settings-row"><span>{t("Microphone")} · {status?.microphone === "granted" ? t("Allowed") : t("Needs access")}<br />{t("Accessibility")} · {status?.accessibility ? t("Allowed") : t("Needs access")}</span><button className="settings-toolbar-button" disabled={!nativeRuntime || busy} aria-label={t("Check Again")} onClick={() => void perform(async () => setStatus(await dictationAction("status")))}><RefreshCw size={15} /></button></div>
    </div>
    <div className="settings-group"><div className="settings-row"><div className="preference-copy"><strong>{t("Dictation Recovery")}</strong><span>{t("Original and processed text are saved on this Mac. Failed recordings are kept so your speech is not lost. Open the folder to recover or delete them.")}</span></div><button className="settings-toolbar-button" disabled={!nativeRuntime || busy} onClick={() => void perform(async () => { await dictationAction("openRecovery"); })}>{t("Open recovery folder")}</button></div></div>
    <div className="dictation-actions">

      {active && <button className="settings-toolbar-button" onClick={() => void perform(async () => setStatus(await dictationAction("cancel")))}><X size={14} />{t("Cancel")}</button>}
      {status?.hasOriginal && <button className="settings-toolbar-button" disabled={busy} onClick={() => void perform(async () => { await dictationAction("copyOriginal"); }, t("복사했습니다."))}>{t("Copy original text")}</button>}
      {status?.hasTranscript && <button className="settings-toolbar-button" disabled={busy} onClick={() => void perform(async () => { await dictationAction("copy"); }, t("복사했습니다."))}>{t("마지막 결과 복사")}</button>}
    </div>
    {status?.recoveryWarning && <p role="alert">{status.recoveryWarning}</p>}
    {status?.shortcutWarning && <p role="alert">{status.shortcutWarning}</p>}
    {status?.message && <p role="status">{t(status.message, {}, locale)}</p>}
    {notice && <p role="status">{notice}</p>}
    {(error || autoSave.error) && <p role="alert">{t(error || autoSave.error)}</p>}
  </div>;
}
