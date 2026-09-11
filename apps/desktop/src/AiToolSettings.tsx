import { SettingsSelect } from "./settings/SettingsSelect";
import { t, useLocale, currentLocale } from "./i18n";
import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { FolderPlus, Globe, FolderOpen, X } from "lucide-react";
import { aiErrorText, notifyAiSettingsChanged, watchAiSettings } from "./providers/ai";
import { defaultAiTools, getAiTools, setAiTools, type AiToolSettings as ToolSettings } from "./providers/aiTools";
export function AiToolSettings({ nativeRuntime }: { nativeRuntime: boolean }) {
  useLocale();
  const [value, setValue] = useState(defaultAiTools);
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    if (!nativeRuntime) return;
    let alive = true;
    const load = () => { void getAiTools().then(v => { if (alive && v) { setValue(v); setReady(true); } }).catch(e => {if(alive)setError(aiErrorText(e));}); };
    load(); const stop = watchAiSettings(load); return () => {alive=false;stop();};
  }, [nativeRuntime]);
  async function update(task: () => Promise<ToolSettings>) {
    if (busy || !nativeRuntime) return;
    setBusy(true); setError("");
    try { const v = await task(); if (!v) throw t("도구 설정 저장을 확인하지 못했습니다."); setValue(v); notifyAiSettingsChanged(); }
    catch (e) {setError(aiErrorText(e));} finally {setBusy(false);}
  }
  const disabled = !ready || busy || !nativeRuntime;
  return <section className="ai-tool-settings" aria-label={t("AI 도구와 접근 권한")}>
    <div className="ai-section-heading"><h3>{t("도구와 접근 권한")}</h3><span>{t("필요한 기능만 켜기")}</span></div>
    <label className="ai-tool-setting"><Globe size={17}/><span><strong>{t("웹 검색 허용")}</strong><small>{t("채팅에서 켜면 AI가 필요한 검색을 실행합니다. Vercel·OpenRouter는 Perplexity Sonar, OpenAI는 내장 검색을 사용하며 추가 요금이 발생할 수 있습니다. 검색어는 검색 서비스에도 전달됩니다.")}</small></span><input type="checkbox" aria-label={t("웹 검색 허용")} checked={value.webSearch} disabled={disabled} onChange={e=>void update(()=>setAiTools({...value,webSearch:e.target.checked}))}/></label>
    <label className="ai-tool-setting"><FolderOpen size={17}/><span><strong>{t("로컬 파일 읽기 허용")}</strong><small>{t("선택한 폴더의 파일명과 필요한 텍스트를 대화의 AI 제공업체로 전송합니다. 파일 수정·명령 실행은 하지 않습니다. 숨김 파일·키 파일은 제외합니다.")}</small></span><input type="checkbox" aria-label={t("로컬 파일 읽기 허용")} checked={value.localFiles} disabled={disabled} onChange={e=>{const enabled=e.target.checked;void update(()=>enabled&&!value.folders.length?invoke("ai_add_folder",{locale:currentLocale()}):setAiTools({...value,localFiles:enabled}));}}/></label>
    <div className="ai-folder-grants">{value.folders.map(folder=><div key={folder.id}><FolderOpen size={14}/><span title={folder.path}>{folder.path}</span><button type="button" aria-label={t("{0} 허용 취소", {"0": folder.path})} disabled={disabled} onClick={()=>void update(()=>invoke("ai_remove_folder",{folderId:folder.id}))}><X size={14}/></button></div>)}<button type="button" disabled={disabled} onClick={()=>void update(()=>invoke("ai_add_folder",{locale:currentLocale()}))}><FolderPlus size={15}/> {t("허용 폴더 추가")}</button><small>{t("텍스트·코드 파일, 파일당 최대 32 KB. PDF·이미지는 아직 지원하지 않습니다.")}</small></div>
    <label className="ai-output-limit"><span><strong>{t("출력·추론 한도")}</strong><small>{t("추론 모델이 답변 전에 한도를 소진하면 높여 주세요. 한도가 클수록 사용량이 늘 수 있습니다.")}</small></span><SettingsSelect label={t("출력 토큰 한도")} disabled={disabled} value={String(value.maxOutputTokens)} onChange={limit => void update(() => setAiTools({...value,maxOutputTokens:Number(limit)}))} options={[4096,16384,32768].map(limit => ({value:String(limit),label:t("{0} tokens", {0:limit.toLocaleString()})}))} /></label>
    {error&&<p role="alert" className="ai-settings-error">{t(error)}</p>}
  </section>;
}
