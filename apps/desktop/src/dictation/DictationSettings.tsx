import { useEffect, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { FolderOpen, Mic, Play, RefreshCw, X } from "lucide-react";
import { currentLocale, t, useLocale } from "../i18n";
import { changeProvider, defaultSettings, dictationAction, getDictationSettings, providers, saveDictationSettings, watchDictation, type DictationSettings as Settings, type DictationStatus } from "./api";
import "./dictation.css";
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

export function DictationSettings({ nativeRuntime, shortcut, onPermissions }: { nativeRuntime: boolean; shortcut: ReactNode; onPermissions(): void }) {
  const locale = useLocale();
  const [saved, setSaved] = useState<Settings>(defaultSettings);
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
  const active = !!status && ["preparing", "recording", "transcribing", "inserting"].includes(status.phase);
  const disabled = !nativeRuntime || !ready || busy || active;
  const remote = draft.provider !== "local";
  const dirty = JSON.stringify(draft) !== JSON.stringify(saved);

  useEffect(() => {
    if (!nativeRuntime) return;
    let alive = true;
    let unlisten: (() => void) | undefined;
    void Promise.all([getDictationSettings(), dictationAction("status")]).then(([settings, state]) => {
      if (!alive) return;
      setDraft(settings); setSaved(settings); setStatus(state); setReady(true);
    }).catch(error => { if (alive) setError(errorText(error)); });
    void watchDictation(state => { if (alive) setStatus(state); }).then(stop => { if (alive) unlisten = stop; else stop(); }).catch(error => { if (alive) setError(errorText(error)); });
    return () => { alive = false; unlisten?.(); };
  }, [nativeRuntime]);
  async function perform(work: () => Promise<unknown>, message = "") {
    if (busy) return;
    setBusy(true); setError(""); setNotice("");
    try { await work(); setNotice(message); } catch (error) { setError(errorText(error)); } finally { setBusy(false); }
  }
  async function pick(kind: "executable" | "model") {
    await perform(async () => { const path = await invoke<string | null>("dictation_pick_file", { kind }); if (path) setDraft(current => ({ ...current, [kind === "model" ? "modelPath" : "whisperPath"]: path })); });
  }
  function changeOverlay(field: "showRecordingShortcutHints" | "showTranscriptionStatus") {
    const next = { ...draft, [field]: !(draft[field] ?? true) };
    setDraft(next);
    if (status?.phase === "preview") void perform(async () => setStatus(await dictationAction("preview", { ...next, uiLanguage: currentLocale() })));
  }
  const delivery = (settings: Settings) => ({
    defaultDelivery: settings.defaultDelivery,
    recordingCancelShortcut: settings.recordingCancelShortcut ?? recordingDefaults.recordingCancelShortcut,
    recordingCopyShortcut: settings.recordingCopyShortcut ?? recordingDefaults.recordingCopyShortcut,
    recordingPasteShortcut: settings.recordingPasteShortcut ?? recordingDefaults.recordingPasteShortcut,
    recordingPasteAndEnterShortcut: settings.recordingPasteAndEnterShortcut ?? recordingDefaults.recordingPasteAndEnterShortcut,
  });
  const deliveryDirty = JSON.stringify(delivery(draft)) !== JSON.stringify(delivery(saved));
  const { defaultDelivery: _defaultDelivery, ...bindings } = delivery(draft);
  const invalidDelivery = recordingConflict(bindings) || Object.values(bindings).some(binding => binding.mode === "custom" && !binding.label);
  async function selectModel(model: string) {
    setBusy(true); setError(""); setNotice("");
    try {
      const settings = await saveDictationSettings({ ...saved, provider: draft.provider, baseURL: draft.baseURL, model, uiLanguage: currentLocale() });
      setSaved(settings); setDraft(current => ({ ...current, provider: settings.provider, baseURL: settings.baseURL, model: settings.model, uiLanguage: settings.uiLanguage }));
      setNotice(t("받아쓰기 설정을 저장했습니다."));
    } catch (error) { setError(errorText(error)); throw error; } finally { setBusy(false); }
  }
  return <div className="dictation-settings">
    <DictationModelSelector settings={draft} disabled={disabled} nativeRuntime={nativeRuntime && ready} configured={configured} keyEpoch={keyEpoch} onProvider={provider => { if (provider === draft.provider) return; setConfigured(false); setDraft(current => changeProvider(current, provider)); setNotice(""); }} onSelect={selectModel} />
    <div className="settings-group">
      <div className="settings-row"><div className="preference-copy"><strong>{t("음성 받아쓰기")}</strong><span>{t("단축키로 녹음을 시작하고, 다시 눌러 현재 앱에 입력하세요.")}</span></div><Mic size={20} /></div>
      <div className="dictation-command">{shortcut}</div>
      <p className="dictation-notice">{t("먼저 단축키 기록 버튼을 클릭한 뒤 Ctrl을 눌렀다 떼고 빠르게 다시 누르세요. 등록되면 ⌃ ⌃가 표시됩니다. 아래 붙여넣고 Enter는 사용자 지정으로 바꾸고 기록 버튼을 클릭한 뒤 Ctrl을 한 번 눌렀다 떼세요.")}</p>
      {nativeRuntime && status && !status.accessibility && <div className="settings-row"><div className="preference-copy"><span>{t("Ctrl 두 번과 Ctrl 단독 단축키에는 현재 실행 중인 Prism의 손쉬운 사용 권한이 필요합니다. 권한을 허용한 뒤 단축키를 다시 기록하세요.")}</span></div><button className="settings-toolbar-button" onClick={onPermissions}>{t("Open Permissions")}</button></div>}
      <div className="settings-row"><div className="preference-copy"><span>{t("같은 단축키로 녹음을 끝내거나, 아래에서 동작별 단축키를 지정하세요. 최대 5분.")}</span></div></div>
    </div>
    <DictationDeliverySettings nativeRuntime={nativeRuntime} settings={draft} disabled={disabled} onChange={setDraft} footer={
      <div className="settings-row"><span role="status">{deliveryDirty ? t("저장하지 않은 변경 사항") : t("저장된 설정")}</span><button className="settings-toolbar-button" disabled={disabled || !deliveryDirty || invalidDelivery} onClick={() => void perform(async () => {
        const fields = delivery(draft);
        const settings = await saveDictationSettings({ ...saved, ...fields, uiLanguage: currentLocale() });
        setSaved(settings); setDraft(current => ({ ...current, ...delivery(settings) }));
      }, t("받아쓰기 설정을 저장했습니다."))}>{t("단축키 저장")}</button></div>
    } />
    <div className="settings-group" role="group" aria-label={t("파형 오버레이")}>
      <div className="settings-row"><div className="preference-copy"><strong>{t("파형 오버레이")}</strong><span>{t("Whisp와 같은 화면 하단 위치에 표시합니다.")}</span></div><button className="settings-toolbar-button" disabled={!nativeRuntime || !ready || active || busy} onClick={() => void perform(async () => setStatus(await dictationAction("preview", { ...draft, uiLanguage: currentLocale() })))}><Play size={14} />{t("파형 미리보기")}</button></div>
      <div className="settings-row"><div className="preference-copy"><strong>{t("녹음 중 단축키 안내")}</strong><span>{t("파형 오른쪽에 취소·붙여넣기·전송 키를 표시합니다.")}</span></div><button className={`switch ${draft.showRecordingShortcutHints ? "active" : ""}`} role="switch" aria-label={t("녹음 중 단축키 안내")} aria-checked={draft.showRecordingShortcutHints ?? true} disabled={disabled} onClick={() => changeOverlay("showRecordingShortcutHints")}><span /></button></div>
      <div className="settings-row"><div className="preference-copy"><strong>{t("전사 상태 표시")}</strong><span>{t("전사 중 파형 옆에 상태 설명을 표시합니다.")}</span></div><button className={`switch ${draft.showTranscriptionStatus ? "active" : ""}`} role="switch" aria-label={t("전사 상태 표시")} aria-checked={draft.showTranscriptionStatus ?? true} disabled={disabled} onClick={() => changeOverlay("showTranscriptionStatus")}><span /></button></div>
    </div>
    {!nativeRuntime && <p className="dictation-notice">{t("받아쓰기는 macOS용 Prism 앱에서 사용할 수 있습니다.")}</p>}
    <div className="settings-group">
      {remote ? <>
        <DictationApiKey key={draft.provider} provider={draft.provider} nativeRuntime={nativeRuntime && ready} disabled={disabled} onConfigured={setConfigured} />
        {draft.provider === "custom" && <label className="dictation-field">API Base URL<input disabled={disabled} value={draft.baseURL} placeholder="https://…/v1" onChange={event => setDraft({ ...draft, baseURL: event.target.value })} /></label>}

      </> : <>
        <p className="dictation-notice">{t("설치된 whisper.cpp와 Whisp의 기존 .bin 모델을 선택하세요. 모델을 자동으로 내려받지 않습니다.")}</p>
        <label className="dictation-field">whisper.cpp<div className="dictation-file"><input disabled={disabled} value={draft.whisperPath} onChange={event => setDraft({ ...draft, whisperPath: event.target.value })} /><button className="settings-toolbar-button" aria-label={t("실행 파일 선택")} disabled={disabled} onClick={() => void pick("executable")}><FolderOpen size={16} /></button></div></label>
        <label className="dictation-field">{t("로컬 모델 파일")}<div className="dictation-file"><input disabled={disabled} value={draft.modelPath} onChange={event => setDraft({ ...draft, modelPath: event.target.value })} placeholder="/…/ggml-model.bin" /><button className="settings-toolbar-button" aria-label={t("모델 파일 선택")} disabled={disabled} onClick={() => void pick("model")}><FolderOpen size={16} /></button></div></label>
      </>}
      <div className="dictation-options" role="group" aria-label={t("받아쓰기 언어")}>{[["auto", "Auto"], ["ko", "한국어"], ["en", "English"]].map(([value, title]) => <button className="settings-toolbar-button" disabled={disabled} key={value} aria-pressed={draft.language === value} onClick={() => setDraft({ ...draft, language: value })}>{title}</button>)}</div>
      <details className="dictation-advanced"><summary>{t("인식 힌트와 단어")}</summary>
        <label className="dictation-field">{t("인식 힌트")}<textarea rows={2} disabled={disabled} maxLength={2000} value={draft.prompt} onChange={event => setDraft({ ...draft, prompt: event.target.value })} /></label>
        <label className="dictation-field">{t("단어 목록 · 한 줄에 하나")}<textarea rows={3} disabled={disabled} value={draft.vocabulary.join("\n")} onChange={event => setDraft({ ...draft, vocabulary: event.target.value.split("\n") })} /></label>
      </details>
      <div className="settings-row"><span>{dirty ? t("저장하지 않은 변경 사항") : t("저장된 설정")}</span><button className="settings-toolbar-button" disabled={disabled || !dirty} onClick={() => void perform(async () => { const settings = await saveDictationSettings({ ...draft, vocabulary: draft.vocabulary.map(word => word.trim()).filter(Boolean), uiLanguage: currentLocale() }); setSaved(settings); setDraft(settings); }, t("받아쓰기 설정을 저장했습니다."))}>{t("Save")}</button></div>
    </div>
    <div className="settings-group"><div className="settings-row"><div className="preference-copy"><strong>{t("Permissions")}</strong><span>{t("녹음에는 마이크 권한, 자동 입력에는 손쉬운 사용 권한이 필요합니다.")}</span></div><button className="settings-toolbar-button" onClick={onPermissions}>{t("Open Permissions")}</button></div>
      <div className="settings-row"><span>{t("Microphone")} · {status?.microphone === "granted" ? t("Allowed") : t("Needs access")}<br />{t("Accessibility")} · {status?.accessibility ? t("Allowed") : t("Needs access")}</span><button className="settings-toolbar-button" disabled={!nativeRuntime || busy} aria-label={t("Check Again")} onClick={() => void perform(async () => setStatus(await dictationAction("status")))}><RefreshCw size={15} /></button></div>
    </div>
    <div className="dictation-actions">

      {active && <button className="settings-toolbar-button" onClick={() => void perform(async () => setStatus(await dictationAction("cancel")))}><X size={14} />{t("Cancel")}</button>}
      {status?.hasTranscript && <button className="settings-toolbar-button" disabled={busy} onClick={() => void perform(async () => { await dictationAction("copy"); }, t("복사했습니다."))}>{t("마지막 결과 복사")}</button>}
    </div>
    <p className="dictation-notice">{t("같은 단축키를 다시 누르면 설정한 기본 동작을 수행합니다. 원격 STT에는 제공자 요금이 발생할 수 있습니다.")}</p>
    {status?.shortcutWarning && <p role="alert">{status.shortcutWarning}</p>}
    {status?.message && <p role="status">{t(status.message, {}, locale)}</p>}
    {notice && <p role="status">{notice}</p>}
    {error && <p role="alert">{t(error)}</p>}
  </div>;
}
