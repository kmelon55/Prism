import { t, useLocale } from "./i18n";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Check, ChevronDown, Search, Sparkles, RefreshCw } from "lucide-react";
import { aiErrorText, aiProviders, formatAiPrice, listAiModels, type AiSelection, type AiProvider, type AiModel } from "./providers/ai";
export function AiModelPicker({ selection, disabled, nativeRuntime, onSelect, onSettings, purpose = "chat" }: { selection: AiSelection; disabled: boolean; nativeRuntime: boolean; onSelect(value: AiSelection): Promise<void>; onSettings(): void; purpose?: "chat" | "dictation" }) {
  useLocale();
  const [open,setOpen]=useState(false);
  const [provider,setProvider]=useState(selection.provider);
  const [models,setModels]=useState<AiModel[]>([]);
  const [query,setQuery]=useState("");
  const [error,setError]=useState("");
  const [loading,setLoading]=useState(false);
  const [saving,setSaving]=useState(false);
  const [revision,setRevision]=useState(0);
  const [limit,setLimit]=useState(35);
  const host=useRef<HTMLDivElement>(null);
  const trigger=useRef<HTMLButtonElement>(null);
  const search=useRef<HTMLInputElement>(null);
  useEffect(()=>{if(disabled)setOpen(false);},[disabled]);
  useEffect(()=>{
    if(!open)return;
    search.current?.focus();
    const outside=(e:PointerEvent)=>{if(!host.current?.contains(e.target as Node))setOpen(false);};
    document.addEventListener("pointerdown",outside);return()=>document.removeEventListener("pointerdown",outside);
  },[open]);
  useEffect(()=>{
    if(!open||!nativeRuntime)return;
    let alive=true;setLoading(true);setModels([]);setError("");
    void listAiModels(provider).then(v=>{if(alive)setModels(v);}).catch(e=>{if(alive)setError(aiErrorText(e));}).finally(()=>{if(alive)setLoading(false);});
    return()=>{alive=false;};
  },[open,provider,nativeRuntime,revision]);
  const filtered=models.filter(m=>`${m.name} ${m.id}`.toLowerCase().includes(query.toLowerCase()));
  async function select(model:AiModel){
    if(saving)return;setSaving(true);setError("");
    try{await onSelect({provider,model:model.id,modelName:model.name});setOpen(false);trigger.current?.focus();}catch(e){setError(aiErrorText(e));}finally{setSaving(false);}
  }
  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!open || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return;
    if (event.key === "Tab") {
      event.preventDefault();
      event.stopPropagation();
      const controls = [...host.current!.querySelectorAll<HTMLElement>(".ai-model-popover button:not(:disabled), .ai-model-popover input:not(:disabled)")];
      const index = controls.indexOf(document.activeElement as HTMLElement);
      const next = index < 0 ? (event.shiftKey ? controls.length - 1 : 0)
        : (index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length;
      controls[next]?.focus();
    } else if (["ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault();
      const rows = [...host.current!.querySelectorAll<HTMLButtonElement>(".ai-picker-results > button:not(:disabled)")];
      const index = rows.indexOf(document.activeElement as HTMLButtonElement);
      const next = index < 0 ? (event.key === "ArrowDown" ? 0 : rows.length - 1)
        : (index + (event.key === "ArrowDown" ? 1 : -1) + rows.length) % rows.length;
      rows[next]?.focus();
    } else if (event.key === "Enter" && event.target === search.current) {
      event.preventDefault();
      if (filtered[0]) void select(filtered[0]);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      setOpen(false);
      trigger.current?.focus();
    }
  }
  return <div className="ai-composer-model" ref={host} onKeyDown={handleKeyDown} onBlur={event => {
    // WebKit can blur the search with no relatedTarget when clicking a button.
    // Outside pointerdown already dismisses the picker; keep inside clicks alive.
    if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget as Node)) setOpen(false);
  }}>
    <button ref={trigger} type="button" className="ai-model-trigger" aria-label={t(purpose === "dictation" ? "Change text processing model" : "대화 모델 변경")} aria-haspopup="dialog" aria-expanded={open} disabled={disabled || saving} onClick={()=>{setProvider(selection.provider);setQuery("");setLimit(35);setOpen(v=>!v);}}><Sparkles size={13}/><span>{selection.modelName||selection.model||t("모델 선택")}</span><ChevronDown size={13}/></button>
    {open&&<div className="ai-model-popover ai-feedback-enter" role="dialog" aria-label={t(purpose === "dictation" ? "Text processing model" : "대화 모델 선택")}>
      <div className="ai-picker-heading"><strong>{t(purpose === "dictation" ? "Text processing model" : "이 대화의 모델")}</strong><button type="button" aria-label={t("대화 모델 새로고침")} disabled={loading||saving} onClick={()=>setRevision(v=>v+1)}><RefreshCw size={13} className={loading?"ai-spinning":""}/></button></div>
      <div className="ai-picker-providers" role="group" aria-label={t("대화 제공업체")}>{(Object.keys(aiProviders) as AiProvider[]).filter(p => purpose !== "dictation" || p !== "compatible").map(p=><button type="button" key={p} aria-pressed={provider===p} disabled={saving} onClick={()=>{setProvider(p);setLimit(35);}}>{p==="vercel"?"Vercel":aiProviders[p].name}</button>)}</div>
      <label className="ai-picker-search"><Search size={14}/><input ref={search} type="search" aria-label={t("대화 모델 검색")} placeholder={t("모델 이름 검색…")} value={query} onChange={e=>{setQuery(e.target.value);setLimit(35);}}/></label>
      <div className="ai-picker-price-heading"><span>{t("모델")}</span><small>{t("입력 / 출력 · USD / 100만 토큰")}</small></div>
      <div className="ai-picker-results" aria-busy={loading}>{filtered.slice(0,limit).map(m=><button type="button" key={m.id} disabled={saving} aria-label={`${m.name} 사용`} aria-pressed={selection.provider===provider&&selection.model===m.id} onClick={()=>void select(m)}><span><strong>{m.name}</strong><small>{m.id}{m.supportsTools ? t(" · 도구 지원") : m.supportsTools === false ? t(" · 텍스트 대화") : ""}</small></span><span className="ai-picker-cost">{formatAiPrice(m.inputPrice)} / {formatAiPrice(m.outputPrice)}{m.pricingVariable?"*":""}</span>{selection.provider===provider&&selection.model===m.id&&<Check size={13}/>}</button>)}{filtered.length>limit&&<button type="button" onClick={()=>setLimit(n=>n+35)}>{t("더 보기")}</button>}{loading&&<p role="status">{t("모델을 불러오는 중…")}</p>}{!loading&&!error&&!filtered.length&&<p>{nativeRuntime?t("일치하는 모델이 없습니다."):t("모델 목록은 데스크톱 앱에서 불러옵니다.")}</p>}</div>
      {provider === "compatible" && query.trim() && !filtered.some(m => m.id === query.trim()) && <button type="button" disabled={saving || !nativeRuntime} onClick={() => void select({id: query.trim(), name: query.trim(), contextWindow: null})}>{t("Use model ID: {0}", {0: query.trim()})}</button>}
      {error&&<p className="ai-error" role="alert">{t(error)}</p>}
      <div className="ai-picker-footer"><small>{t(purpose === "dictation" ? "Applies only to this enhancement." : "기존 대화를 유지하고 다음 답변부터 적용합니다.")}</small><button type="button" onClick={()=>{setOpen(false);onSettings();}}>{t("API 키·도구 설정")}</button></div>
    </div>}
  </div>;
}
