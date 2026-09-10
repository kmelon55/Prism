import { useEffect, useRef, useState, type ReactNode } from "react";
import { useShortcutCaptureLease } from "../settings/shortcutCapture";
import { t } from "../i18n";
import type { DictationSettings } from "./api";
import { captureRecordingKey, singleModifier, recordingConflict, recordingDefaults, type RecordingAction } from "./recordingShortcuts";
export function DictationDeliverySettings({ settings, disabled, onChange, footer, nativeRuntime = false }: { settings: DictationSettings; nativeRuntime?: boolean; disabled: boolean; footer?: ReactNode; onChange(settings: DictationSettings): void }) {
  const [recording,setRecording]=useState<RecordingAction>();
  const [error,setError]=useState("");
  const candidate=useRef<string | undefined>(undefined);
  useEffect(() => {
    const cancel = () => { setRecording(undefined); candidate.current = undefined; };
    window.addEventListener("blur", cancel);
    if (disabled) cancel();
    return () => window.removeEventListener("blur", cancel);
  }, [disabled]);
  const captureLease = useShortcutCaptureLease(nativeRuntime, !!recording, "dictation", () => { setRecording(undefined); candidate.current = undefined; });
  const bindings={recordingCopyShortcut:settings.recordingCopyShortcut??recordingDefaults.recordingCopyShortcut,recordingCancelShortcut:settings.recordingCancelShortcut??recordingDefaults.recordingCancelShortcut,recordingPasteShortcut:settings.recordingPasteShortcut??recordingDefaults.recordingPasteShortcut,recordingPasteAndEnterShortcut:settings.recordingPasteAndEnterShortcut??recordingDefaults.recordingPasteAndEnterShortcut};
  const rows: [RecordingAction,string,string][]=[
    ["recordingCancelShortcut","취소","API 요청 없이 녹음을 버립니다."],
    ["recordingCopyShortcut","클립보드에만 복사","붙여넣기 없이 결과를 복사합니다."],
    ["recordingPasteShortcut","붙여넣기","기본이 복사여도 이 단축키는 붙여넣습니다."],
    ["recordingPasteAndEnterShortcut","붙여넣고 Enter","붙여넣은 뒤 Enter까지 눌러 전송합니다."],
  ];
  return <div className="settings-group" role="group" aria-label={t("결과와 녹음 단축키")}>
    <div className="settings-row"><div className="preference-copy"><strong>{t("기본 결과 동작")}</strong><span>{t("녹음 시작 단축키를 다시 눌렀을 때의 동작입니다.")}</span></div><select aria-label={t("기본 결과 동작")} disabled={disabled} value={settings.defaultDelivery??"paste"} onChange={event=>onChange({...settings,defaultDelivery:event.target.value as "copy"|"paste"})}><option value="copy">{t("클립보드에만 복사")}</option><option value="paste">{t("입력 위치에 붙여넣기")}</option></select></div>
    <p className="dictation-notice">{t("입력 위치를 찾지 못하면 클립보드에만 복사하며, Enter를 보내지 않습니다.")}</p>
    {rows.map(([action,title,description])=>{
      const binding=bindings[action];
      return <div className="settings-row" key={action}><div className="preference-copy"><strong>{t(title)}</strong><span>{t(description)}</span></div><div className="dictation-recording-controls">
        <select aria-label={t("{0} 단축키 방식",{0:t(title)})} disabled={disabled||!!recording} value={binding.mode} onChange={event=>{setError("");onChange({...settings,[action]:{...binding,mode:event.target.value}});}}>
          {action==="recordingPasteShortcut"&&<option value="sameAsPrimary">{t("녹음 시작과 동일 · 기본 동작")}</option>}
          <option value="custom">{t("사용자 지정")}</option><option value="disabled">{t("지정 안 함")}</option>
        </select>
        {binding.mode==="custom"&&<button className="shortcut-recorder" disabled={disabled} aria-label={t("{0} 단축키 기록",{0:t(title)})} aria-pressed={recording===action} onClick={event=>{event.currentTarget.focus();setRecording(recording===action?undefined:action);candidate.current=undefined;setError("");}} onBlur={()=>{setRecording(undefined);candidate.current=undefined;}} onKeyDown={event=>{
          if(recording!==action || !captureLease.ready)return;event.preventDefault();event.stopPropagation();
          if(event.nativeEvent.isComposing || event.repeat)return;
          if(singleModifier(event.key)){candidate.current=candidate.current===undefined?event.key:candidate.current===event.key?event.key:"";return;}
          candidate.current=undefined;const next=captureRecordingKey(event.nativeEvent);
          if(next){onChange({...settings,[action]:next});setRecording(undefined);}else setError(t("이 키는 사용할 수 없습니다. 다른 키를 눌러 주세요."));
        }} onKeyUp={event=>{
          if(recording!==action || !captureLease.ready)return;event.preventDefault();event.stopPropagation();
          if(candidate.current===event.key){const next=singleModifier(event.key);if(next){onChange({...settings,[action]:next});setRecording(undefined);}}candidate.current=undefined;
        }}>{recording===action?t("단축키를 누르세요…"):binding.label||t("단축키 기록")}</button>}
        {recording===action&&<button className="settings-toolbar-button" onClick={()=>setRecording(undefined)}>{t("Cancel")}</button>}
      </div></div>;
    })}
    {recordingConflict(bindings)&&<p role="alert" className="dictation-notice">{t("녹음 동작마다 다른 단축키를 지정하세요.")}</p>}
    {error&&<p role="alert">{error}</p>}
    {captureLease.error&&<p role="alert">{t(captureLease.error)}</p>}
    {footer}
    <p className="dictation-notice">{t("녹음 중에만 사용하는 단축키입니다. 조합 키 또는 보조 키 하나를 지정할 수 있습니다. 보조 키 단독 사용은 손쉬운 사용 권한이 필요합니다.")}</p>
  </div>;
}
