import { AiUsage } from "./AiUsage";
import { AnimatePresence } from "motion/react";
import { AnimatedPanel } from "./settings/InterfaceMotion";
import { t, useLocale } from "./i18n";
import { AiToolSettings } from "./AiToolSettings";
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Check, ChevronDown, X, ExternalLink, RefreshCw, Search } from "lucide-react";
import { aiErrorText, aiProviders, formatAiPrice, listAiModels, loadAiSelection, notifyAiSettingsChanged, readAiSelection, saveAiSelection, watchAiSettings, type AiKeyInfo, type AiModel, type AiProvider } from "./providers/ai";

export function AiSettings({ nativeRuntime }: { nativeRuntime: boolean }) {
  useLocale();
  const [saved, setSaved] = useState(readAiSelection);
  const [provider, setProvider] = useState<AiProvider>(saved.provider);
  const [ready, setReady] = useState(!nativeRuntime);
  const [keyInfo, setKeyInfo] = useState<AiKeyInfo | null>(null);
  const [key, setKey] = useState("");
  const [editing, setEditing] = useState(false);
  const [checking, setChecking] = useState(false);
  const [savingKey, setSavingKey] = useState(false);
  const [savingModel, setSavingModel] = useState("");
  const [modelsOpen, setModelsOpen] = useState(false);
  const selector = useRef<HTMLElement>(null);
  const modelTrigger = useRef<HTMLButtonElement>(null);
  const modelSearch = useRef<HTMLInputElement>(null);
  const [models, setModels] = useState<AiModel[]>([]);
  const [loading, setLoading] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<"name" | "input" | "output">("name");
  const [limit, setLimit] = useState(40);
  const [keyError, setKeyError] = useState("");
  const [unlockError, setUnlockError] = useState("");
  const [error, setError] = useState("");
  const [modelError, setModelError] = useState("");
  const [notice, setNotice] = useState("");
  const [catalogRevision, setCatalogRevision] = useState(0);
  const [keyRevision, setKeyRevision] = useState(0);
  const providerRef = useRef(provider);
  const mounted = useRef(false);
  const mutation = useRef(false);
  const providerInfo = aiProviders[provider];

  useEffect(() => {
    mounted.current = true;
    let active = true;
    void loadAiSelection(nativeRuntime).then((selection) => {
      if (!active) return;
      setSaved(selection); setProvider(selection.provider); providerRef.current = selection.provider; setReady(true);
    }).catch((error) => { if (active) { setError(aiErrorText(error)); setReady(true); } });
    const stop = watchAiSettings(() => {
      if (mutation.current) return;
      setKeyRevision((value) => value + 1);
      void loadAiSelection(nativeRuntime).then((selection) => { if (active) setSaved(selection); })
        .catch((error) => { if (active) setError(aiErrorText(error)); });
    });
    return () => { active = false; mounted.current = false; stop(); };
  }, [nativeRuntime]);

  useEffect(() => {
    if (!nativeRuntime || !ready) return;
    let active = true;
    setChecking(true); setKeyError("");
    void invoke<AiKeyInfo>("ai_key_info", { provider }).then((info) => {
      if (active) setKeyInfo(info);
    }).catch((error) => { if (active) setKeyError(aiErrorText(error)); })
      .finally(() => { if (active) setChecking(false); });
    return () => { active = false; };
  }, [provider, nativeRuntime, ready, keyRevision]);

  // Public catalogs are independent of Keychain status. Refresh never clears the key editor.
  const canLoad = nativeRuntime && ready && (provider !== "openai" || keyInfo?.configured === true && keyInfo.unlocked !== false);
  useEffect(() => {
    if (!canLoad) { setLoading(false); return; }
    let active = true;
    setLoading(true); setModelError("");
    void listAiModels(provider).then((result) => {
      if (active) { setModels(result); setLoaded(true); }
    }).catch((error) => { if (active) setModelError(aiErrorText(error)); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [provider, canLoad, catalogRevision]);

  useEffect(() => {
    if (!modelsOpen) return;
    modelSearch.current?.focus();
    const outside = (event: PointerEvent) => { if (!selector.current?.contains(event.target as Node)) setModelsOpen(false); };
    document.addEventListener("pointerdown", outside);
    return () => document.removeEventListener("pointerdown", outside);
  }, [modelsOpen]);
  function closeModels() { setModelsOpen(false); modelTrigger.current?.focus(); }
  function changeProvider(next: AiProvider) {
    if (next === provider || mutation.current) return;
    providerRef.current = next; setProvider(next); setKeyInfo(null); setChecking(nativeRuntime);
    setKey(""); setEditing(false); setKeyError(""); setUnlockError(""); setModels([]); setLoaded(false); setModelError("");
    setQuery(""); setLimit(40); setNotice(""); setError("");
  }
  async function updateKey(remove = false) {
    if (mutation.current || !nativeRuntime || (!remove && !key.trim())) return;
    mutation.current = true; setSavingKey(true); setKeyError(""); setUnlockError(""); setNotice("");
    const destination = provider;
    try {
      let info: AiKeyInfo;
      if (remove) {
        await invoke("ai_delete_key", { provider });
        info = await invoke<AiKeyInfo>("ai_key_info", { provider });
        if (info.configured) throw t("키 삭제를 확인하지 못했습니다. 다시 시도하세요.");
      } else {
        info = await invoke<AiKeyInfo>("ai_save_key", { provider, key: key.trim() });
        if (!info?.configured) throw t("저장된 키를 확인하지 못했습니다. 다시 시도하세요.");
      }
      if (mounted.current && providerRef.current === destination) {
        setKeyInfo(info); setKey(""); setEditing(false);
        if (destination === "openai") { setModels([]); setLoaded(false); setCatalogRevision((value) => value + 1); }
        setNotice(remove ? t("API 키를 삭제했습니다.") : t("API 키를 키체인에 저장했습니다. 이 앱에서 바로 사용할 수 있습니다."));
      }
      notifyAiSettingsChanged();
    } catch (error) { if (mounted.current && providerRef.current === destination) setKeyError(aiErrorText(error)); }
    finally { mutation.current = false; if (mounted.current) setSavingKey(false); }
  }
  async function unlockKey() {
    if (mutation.current || !nativeRuntime) return;
    mutation.current = true; setSavingKey(true); setKeyError(""); setUnlockError("");
    const destination = provider;
    try {
      const info = await invoke<AiKeyInfo>("ai_unlock_key", {provider});
      if (!info?.configured || info.unlocked === false) throw t("저장된 키를 사용할 수 없습니다. API 키를 다시 저장하세요.");
      if (mounted.current && providerRef.current === destination) {setKeyInfo(info);setNotice(t("이 앱이 실행되는 동안 승인한 키를 재사용합니다."));}
      notifyAiSettingsChanged();
    } catch (error) {if(mounted.current && providerRef.current === destination)setUnlockError(aiErrorText(error));}
    finally {mutation.current=false;if(mounted.current)setSavingKey(false);}
  }
  async function selectModel(entry: AiModel) {
    if (mutation.current || !nativeRuntime) return;
    mutation.current = true; setSavingModel(entry.id); setError(""); setNotice("");
    try {
      const selection = await saveAiSelection({ provider, model: entry.id, modelName: entry.name }, true);
      if (mounted.current) { setSaved(selection); closeModels(); setNotice(t("{0} 모델을 저장했습니다.{1}", {"0": entry.name,"1": keyInfo?.configured ? t(" AI Chat에서 사용할 수 있습니다.") : t(" API 키를 저장하면 사용할 수 있습니다.")})); }
    } catch (error) { if (mounted.current) setError(aiErrorText(error)); }
    finally { mutation.current = false; if (mounted.current) setSavingModel(""); }
  }
  function openUrl(url: string) {
    if (nativeRuntime) void invoke("open_web_url", { url }).catch(() => setError(t("페이지를 열지 못했습니다.")));
    else window.open(url, "_blank", "noopener,noreferrer");
  }
  const filtered = models.filter((entry) => `${entry.name} ${entry.id}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
    .sort((a, b) => (sort === "input" ? (a.inputPrice ?? Infinity) - (b.inputPrice ?? Infinity) : sort === "output" ? (a.outputPrice ?? Infinity) - (b.outputPrice ?? Infinity) : 0) || a.name.localeCompare(b.name));
  const activeModel = saved.provider === provider ? models.find((entry) => entry.id === saved.model) : undefined;
  const busy = savingKey || Boolean(savingModel);

  const modelMenu = modelsOpen ? (<AnimatedPanel className="ai-model-settings ai-settings-model-popover" role="dialog" aria-label={t("기본 모델 선택")} onKeyDown={(event) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closeModels(); }
      if (["ArrowDown", "ArrowUp"].includes(event.key)) {
        event.preventDefault();
        const rows = [...selector.current!.querySelectorAll<HTMLButtonElement>(".ai-model-option:not(:disabled)")];
        const index = rows.indexOf(document.activeElement as HTMLButtonElement);
        rows[(index + (event.key === "ArrowDown" ? 1 : index < 0 ? 0 : -1) + rows.length) % rows.length]?.focus();
      }
      if (event.key === "Enter" && event.target === modelSearch.current) { event.preventDefault(); if (filtered[0]) void selectModel(filtered[0]); }
    }} onBlur={(event) => { if (event.relatedTarget && !selector.current?.contains(event.relatedTarget as Node)) setModelsOpen(false); }}>
      <div className="ai-section-heading"><h3>{t("기본 모델")}<small>{loaded ? t("{0}개", {"0": models.length}) : ""}</small></h3><button type="button" aria-label={t("모델 목록 새로고침")} disabled={!canLoad || loading || busy} onClick={() => setCatalogRevision((value) => value + 1)}><RefreshCw size={13} className={loading ? "ai-spinning" : ""} />{loading ? t("불러오는 중") : t("새로고침")}</button><button type="button" aria-label={t("모델 선택 닫기")} onClick={closeModels}><X size={15}/></button></div>
      <div className="ai-picker-providers" role="group" aria-label={t("모델 제공업체")}>{(Object.keys(aiProviders) as AiProvider[]).map(id => <button key={id} type="button" aria-pressed={provider === id} disabled={busy} onClick={() => changeProvider(id)}>{id === "vercel" ? "Vercel" : aiProviders[id].name}</button>)}</div>
      <label className="ai-model-search"><Search size={15} /><input ref={modelSearch} type="search" aria-label={t("모델 검색")} placeholder={t("모델 이름이나 제작사 검색")} value={query} onChange={(event) => { setQuery(event.target.value); setLimit(40); }} /></label>
      <p className="ai-price-unit">{t("USD / 100만 토큰 · 기본 요금")}</p>
      <div className="ai-model-columns"><button type="button" aria-pressed={sort === "name"} onClick={() => setSort("name")}>{t("모델")}{sort === "name" ? " ↑" : ""}</button><button type="button" aria-pressed={sort === "input"} onClick={() => setSort("input")}>{t("입력")}{sort === "input" ? " ↑" : ""}</button><button type="button" aria-pressed={sort === "output"} onClick={() => setSort("output")}>{t("출력")}{sort === "output" ? " ↑" : ""}</button></div>
      {error && <p role="alert" className="ai-settings-error">{t(error)}</p>}
      {modelError && <p role="alert" className="ai-settings-error">{t(modelError)} {t("새로고침으로 다시 시도하세요.")}</p>}
      {!nativeRuntime ? <p className="ai-settings-note">{t("데스크톱 앱에서 실제 모델 목록을 불러옵니다.")}</p>
        : provider === "openai" && (!keyInfo?.configured || keyInfo.unlocked === false) ? <p className="ai-settings-note">{t("OpenAI는 API 키를 저장하거나 키 사용을 허용하면 모델을 불러옵니다.")}</p>
        : !loading && loaded && !filtered.length ? <p role="status" className="ai-settings-note">{models.length ? t("검색 결과가 없습니다.") : t("사용 가능한 텍스트 모델이 없습니다.")}</p> : null}
      <div className="ai-model-list" aria-label={t("사용할 AI 모델")} aria-busy={loading}>
        {filtered.slice(0, limit).map((entry) => {
          const selected = saved.provider === provider && saved.model === entry.id;
          return <button type="button" className={`ai-model-option${selected ? " selected" : ""}`} key={entry.id} aria-label={t("{0} 선택", {"0": entry.name})} aria-pressed={selected} disabled={busy || !ready} onClick={() => void selectModel(entry)}>
            <span className="ai-model-name"><strong>{entry.name}{selected && <Check size={14} />}</strong><small>{entry.id}{entry.contextWindow ? t(" · {0} 토큰", {"0": new Intl.NumberFormat("ko-KR", { notation: "compact" }).format(entry.contextWindow)}) : ""}</small>{savingModel === entry.id && <small>{t("저장 중…")}</small>}</span>
            <span className="ai-model-price" title={entry.pricingVariable ? t("사용량 구간이나 제공 경로에 따라 요금이 달라집니다.") : undefined}>{formatAiPrice(entry.inputPrice)}{entry.pricingVariable && entry.inputPrice != null ? "*" : ""}</span><span className="ai-model-price" title={entry.pricingVariable ? t("사용량 구간이나 제공 경로에 따라 요금이 달라집니다.") : undefined}>{formatAiPrice(entry.outputPrice)}{entry.pricingVariable && entry.outputPrice != null ? "*" : ""}</span>
          </button>;
        })}
        {filtered.length > limit && <button className="ai-model-more" type="button" onClick={() => setLimit((value) => value + 40)}>{t("더 보기 (")}{filtered.length - limit}{t("개)")}</button>}
      </div>
      <p className="ai-settings-note ai-pricing-note">{t("USD / 100만 토큰 · 제공업체 API의 기본 요금입니다. * 구간·경로에 따라 요금 변동. 캐시 등 추가 조건은 별도입니다.")}{provider === "openai" && <> {t("OpenAI 목록 API는 가격을 제공하지 않습니다.")}<button type="button" onClick={() => openUrl("https://developers.openai.com/api/docs/pricing")}>{t("공식 요금표")}<ExternalLink size={11} /></button></>}</p>
      {loaded && saved.provider === provider && saved.model && !activeModel && <p className="ai-settings-note">{t("저장한 모델이 현재 목록에 없습니다. 현재 선택은 유지되며 다른 모델로 바꿀 수 있습니다.")}</p>}
    </AnimatedPanel>) : null;

  return <div className="ai-settings" aria-label={t("AI 설정")}>
    {!nativeRuntime && <p className="ai-settings-note">{t("브라우저 미리보기입니다. 키 저장과 모델 조회는 macOS 앱에서 사용할 수 있습니다.")}</p>}
    <section ref={selector} className="ai-current-model" aria-label={t("현재 AI 모델")}>
      <div className="ai-current-model-copy">
      <span className="ai-eyebrow">{t("현재 모델")}</span>
      <strong>{!ready ? t("저장된 모델 확인 중…") : saved.model ? saved.modelName || saved.model : t("모델을 선택하세요")}</strong>
      <small>{saved.model ? `${aiProviders[saved.provider].name} · ${saved.model}` : t("모델 선택을 눌러 검색하고 기본 모델을 지정하세요.")}</small>
      {activeModel && <small>{t("입력")}{formatAiPrice(activeModel.inputPrice)} {t("· 출력")}{formatAiPrice(activeModel.outputPrice)} {t("/ 100만 토큰")}</small>}
      </div>
      <button ref={modelTrigger} type="button" className="ai-settings-model-trigger" aria-label={t("기본 모델 변경")} aria-haspopup="dialog" aria-expanded={modelsOpen} disabled={!ready || busy} onClick={() => {setQuery("");setLimit(40);setModelsOpen(value => !value);}}>{saved.model ? t("모델 변경") : t("모델 선택")}<ChevronDown size={14}/></button>
      <AnimatePresence initial={false}>{modelMenu}</AnimatePresence>
    </section>
    <section className="ai-connection" aria-label={t("AI 연결")}>
      <div className="ai-section-heading"><h3>{t("제공업체")}</h3><span>{t("본인 API 키로 연결")}</span></div>
      <div className="ai-provider-options" role="group" aria-label={t("AI 제공업체")}>
        {(Object.keys(aiProviders) as AiProvider[]).map((id) => <button key={id} type="button" aria-pressed={provider === id} disabled={busy || !ready} onClick={() => changeProvider(id)}>{aiProviders[id].name}{provider === id && <Check size={14} />}</button>)}
      </div>
      <div className="ai-key-heading"><span>{providerInfo.description}</span><button type="button" onClick={() => openUrl(providerInfo.keyUrl)}>{t("키 발급")}<ExternalLink size={12} /></button></div>
      {keyInfo?.configured && <div className="ai-saved-key"><Check size={15} /><strong>{t("키 저장됨")}</strong><code aria-label={t("저장된 API 키")}>{keyInfo.maskedKey || t("macOS 키체인에 보관됨")}</code>{keyInfo.unlocked === false && <button type="button" disabled={busy || checking} onClick={() => void unlockKey()}>{t("키 사용 허용")}</button>}<button type="button" disabled={busy || checking} onClick={() => { setEditing(true); setNotice(""); }}>{t("변경")}</button><button type="button" disabled={busy || checking} onClick={() => void updateKey(true)}>{t("삭제")}</button></div>}
      {keyInfo?.configured && keyInfo.unlocked === false && <p className="ai-settings-note">{t("저장된 키는 유지됩니다. 승인이 필요하면 ‘키 사용 허용’을 눌러 주세요. 채팅이나 받아쓰기가 비밀번호 창을 자동으로 열지 않습니다.")}</p>}
      {checking && <p className="ai-settings-note" role="status">{t("저장된 키 확인 중…")}</p>}
      {!checking && !keyInfo && nativeRuntime && keyError && <p className="ai-settings-note">{t("키 저장 상태를 확인하지 못했습니다.")}<button type="button" onClick={() => setKeyRevision((value) => value + 1)}>{t("다시 확인")}</button></p>}
      {(!keyInfo?.configured || editing) && <form className="ai-key-form" onSubmit={(event) => { event.preventDefault(); void updateKey(); }}>
        <label className="ai-key-controls"><input type="password" value={key} aria-label={t("API 키")} placeholder={editing ? t("새 API 키 붙여넣기") : t("API 키 붙여넣기")} onChange={(event) => setKey(event.target.value)} maxLength={4096} disabled={!nativeRuntime || busy || checking || !ready} autoComplete="off" spellCheck={false} autoFocus={editing} />
          <button type="submit" disabled={!nativeRuntime || busy || checking || !ready || !key.trim()}>{savingKey ? t("저장 중…") : t("키 저장")}</button>{editing && <button type="button" disabled={busy} onClick={() => { setEditing(false); setKey(""); setKeyError(""); }}>{t("취소")}</button>}</label>
        {keyInfo && !keyInfo.configured && <small className="ai-settings-note">{t("저장된 키 없음 · 키는 macOS 키체인에 보관합니다.")}</small>}
      </form>}
      {(keyError || unlockError) && <p className="ai-settings-error" role="alert">{t(keyError || unlockError)}</p>}
    </section>
    <AiToolSettings nativeRuntime={nativeRuntime} />
    <AiUsage nativeRuntime={nativeRuntime} />
    {error && <p className="ai-settings-error" role="alert">{t(error)}</p>}
    <p className="ai-settings-notice" role="status">{notice || t("모델을 클릭하면 저장됩니다. 메시지를 보낼 때 선택한 제공업체에 사용료가 청구됩니다.")}</p>
  </div>;
}
