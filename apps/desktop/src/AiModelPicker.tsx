import { ModelPickerDialog } from "./model-picker/ModelPickerDialog";
import { createModelSearch } from "./model-picker/modelSearch";
import { ModelColumns, ModelPrice, ModelSpeed, ModelMetricLegend, type ModelSort } from "./model-picker/ModelMetrics";
import { t, useLocale } from "./i18n";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Check, ChevronDown, Search, Sparkles, RefreshCw, X } from "lucide-react";
import { aiErrorText, aiProviders, listAiModels, type AiSelection, type AiProvider, type AiModel } from "./providers/ai";
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
  const [sort,setSort]=useState<ModelSort>("name");
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
  useEffect(() => { host.current?.querySelector(".model-catalog-list")?.scrollTo({top: 0}); }, [query, provider, sort]);
  const filtered=models.filter(createModelSearch(query))
    .sort((a,b)=>(sort === "input" ? (a.inputPrice ?? Infinity) - (b.inputPrice ?? Infinity) : sort === "output" ? (a.outputPrice ?? Infinity) - (b.outputPrice ?? Infinity) : 0) || a.name.localeCompare(b.name));
  async function select(model:AiModel){
    if(saving)return;setSaving(true);setError("");
    try{await onSelect({provider,model:model.id,modelName:model.name});setOpen(false);trigger.current?.focus();}catch(e){setError(aiErrorText(e));}finally{setSaving(false);}
  }
  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!open || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return;
    if (["ArrowDown", "ArrowUp"].includes(event.key)) {
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
    {open&&<ModelPickerDialog returnFocusRef={trigger} onDismiss={() => setOpen(false)} aria-label={t(purpose === "dictation" ? "Text processing model" : "대화 모델 선택")}>
      <div className="ai-picker-heading"><strong>{t(purpose === "dictation" ? "Text processing model" : "이 대화의 모델")}</strong><span className="model-count">{!loading && t("{0}개", {0: filtered.length})}</span><button type="button" aria-label={t("대화 모델 새로고침")} disabled={loading||saving} onClick={()=>setRevision(v=>v+1)}><RefreshCw size={15} className={loading?"ai-spinning":""}/></button><button type="button" aria-label={t("모델 선택 닫기")} onClick={() => setOpen(false)}><X size={18}/></button></div>
      <div className="ai-picker-providers" role="group" aria-label={t("대화 제공업체")}>{(Object.keys(aiProviders) as AiProvider[]).filter(p => purpose !== "dictation" || p !== "compatible").map(p=><button type="button" key={p} aria-pressed={provider===p} disabled={saving} onClick={()=>{setProvider(p);setLimit(35);}}>{p==="vercel"?"Vercel":aiProviders[p].name}</button>)}</div>
      <label className="ai-picker-search"><Search size={14}/><input ref={search} type="search" aria-label={t("대화 모델 검색")} placeholder={t("모델 이름 검색…")} value={query} onChange={e=>{setQuery(e.target.value);setLimit(35);}}/></label>
      <ModelColumns sort={sort} onSort={value => { setSort(value); setLimit(35); }}/>
      <div className="ai-picker-results model-catalog-list" aria-busy={loading}>{filtered.slice(0,limit).map(m => {
        const selected = selection.provider === provider && selection.model === m.id;
        return <button type="button" className="model-catalog-row" key={m.id} disabled={saving} aria-label={`${m.name} 사용`} aria-pressed={selected} onClick={() => void select(m)}>
          <span className="model-catalog-name"><strong>{m.name}{selected && <Check size={15}/>}</strong><small title={m.id}>{m.id}</small><span className="model-capabilities">{m.contextWindow ? <span>{new Intl.NumberFormat("en", {notation:"compact"}).format(m.contextWindow)} {t("컨텍스트")}</span> : null}{m.supportsImages && <span>{t("이미지")}</span>}{m.supportsTools && <span>{t("도구")}</span>}</span></span>
          <ModelPrice price={m.inputPrice} variable={m.pricingVariable}/><ModelPrice price={m.outputPrice} variable={m.pricingVariable}/><ModelSpeed model={m.id} provider={provider}/>
        </button>;
      })}{filtered.length>limit&&<button type="button" className="model-catalog-more" onClick={()=>setLimit(n=>n+35)}>{t("더 보기")} · {filtered.length-limit}</button>}{loading&&<p role="status">{t("모델을 불러오는 중…")}</p>}{!loading&&!error&&!filtered.length&&<p>{nativeRuntime?t("일치하는 모델이 없습니다."):t("모델 목록은 데스크톱 앱에서 불러옵니다.")}</p>}</div>
      <ModelMetricLegend/>
      {provider === "compatible" && query.trim() && !filtered.some(m => m.id === query.trim()) && <button type="button" disabled={saving || !nativeRuntime} onClick={() => void select({id: query.trim(), name: query.trim(), contextWindow: null})}>{t("Use model ID: {0}", {0: query.trim()})}</button>}
      {error&&<p className="ai-error" role="alert">{t(error)}</p>}
      <div className="ai-picker-footer"><small>{t(purpose === "dictation" ? "Applies only to this enhancement." : "기존 대화를 유지하고 다음 답변부터 적용합니다.")}</small><button type="button" onClick={()=>{setOpen(false);onSettings();}}>{t("API 키·도구 설정")}</button></div>
    </ModelPickerDialog>}
  </div>;
}
