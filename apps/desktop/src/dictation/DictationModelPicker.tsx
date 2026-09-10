import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { RefreshCw, Check, Search } from "lucide-react";
import { t } from "../i18n";
import type { DictationProvider } from "./api";
export interface DictationModel {
  id: string; name: string; description: string; ownedBy: string;
  batchCompatible: boolean; unavailableReason: string | null; free: boolean;
  pricing: Record<string, string | number | null> | null;
}
export interface DictationCatalog { models: DictationModel[]; source: string; mode: "catalog" | "fixed" }
// Whisp VercelModelCatalog.priceText: duration/hour first, then audio input/output tokens.
export function modelPrice(model: DictationModel): string {
  if (model.free) return t("무료");
  const number = (value: unknown) => { const parsed = value == null || value === "" ? NaN : Number(value); return Number.isFinite(parsed) && parsed >= 0 ? parsed : null; };
  const pricing = model.pricing;
  const duration = number(pricing?.transcription_duration_cost_per_second);
  const format = (value: number) => new Intl.NumberFormat("en-US", { maximumFractionDigits: 4, minimumFractionDigits: 2 }).format(value);
  if (duration !== null) return `$${format(duration * 3600)}/${t("hr")}`;
  const input = number(pricing?.audio_input_token_cost ?? pricing?.input);
  const output = number(pricing?.output);
  if (input !== null && output !== null) return `$${format(input * 1e6)} / $${format(output * 1e6)} · ${t("입력 / 출력 · 100만 토큰")}`;
  return t("가격 미제공");
}
interface Props { provider: DictationProvider; baseURL: string; model: string; keyEpoch: number; configured: boolean; nativeRuntime: boolean; disabled: boolean; onSelect(model: string): void }
export function DictationModelPicker(props: Props) {
  const { provider, baseURL, model, keyEpoch, configured, nativeRuntime, disabled, onSelect } = props;
  const [revision, setRevision] = useState(0);
  const [query, setQuery] = useState("");
  const [manualModel, setManualModel] = useState(model);
  useEffect(() => setManualModel(model), [model, provider]);
  useEffect(() => setQuery(""), [provider]);
  const [state, setState] = useState<{ identity: string; catalog?: DictationCatalog; error?: string; loading?: boolean }>();
  const identity = JSON.stringify([provider, baseURL, keyEpoch, configured, revision]);
  const canLoad = nativeRuntime && (provider === "vercel" || provider === "xai" || configured) && !!baseURL;
  useEffect(() => {
    if (!canLoad) return;
    let alive = true;
    setState({ identity, loading: true });
    // Debounce endpoint edits; cleanup also excludes superseded provider/key responses.
    const timer = setTimeout(() => {
      void invoke<DictationCatalog>("dictation_list_models", { provider, baseUrl: baseURL }).then(catalog => {
        if (!catalog || !Array.isArray(catalog.models)) throw new Error(t("모델 목록 응답을 읽지 못했습니다."));
        if (alive) setState({ identity, catalog });
      }).catch(error => { if (alive) setState({ identity, error: error instanceof Error ? error.message : String(error) }); });
    }, provider === "custom" ? 350 : 0);
    return () => { alive = false; clearTimeout(timer); };
  }, [identity, canLoad, provider, baseURL]);
  const current = state?.identity === identity ? state : undefined;
  const catalog = current?.catalog;
  const loading = canLoad && (!current || current.loading);
  return <div className="dictation-model-picker">
    <div className="settings-row"><strong>{t("STT 모델")}</strong><button className="settings-toolbar-button" disabled={!canLoad || disabled} onClick={() => setRevision(value => value + 1)}><RefreshCw size={14} />{t("Refresh models")}</button></div>
    {provider === "xai" ? <><p className="dictation-notice">{t("xAI /stt는 서버가 전사 모델을 자동 선택합니다. 모델 선택 API를 제공하지 않습니다.")}</p><button className="settings-toolbar-button" disabled={disabled} onClick={() => onSelect("grok-stt")}>{t("이 제공자 사용")}</button></> : <>
        <label className="ai-model-search"><Search size={15} /><input type="search" aria-label={t("모델 검색")} placeholder={t("모델 이름이나 제작사 검색")} value={query} onChange={event => setQuery(event.target.value)} /></label>
      {!canLoad && <p className="dictation-notice">{t("지원 모델을 불러오려면 API 키와 주소를 설정하세요.")}</p>}
      {loading && <p className="dictation-notice" role="status">{t("지원 모델을 불러오는 중…")}</p>}
      {current?.error && <p role="alert" className="dictation-notice">{t(current.error)}</p>}
      {catalog && <>
        <p className="dictation-notice">{t("제공자 API에서 확인한 전사 모델")} · {catalog.models.length}</p>
        {catalog.models.length === 0 && <p role="status" className="dictation-notice">{t("API 응답에 확인 가능한 파일 전사 모델이 없습니다. 서버 문서를 확인하거나 모델 ID를 직접 입력하세요.")}</p>}

        {query && !catalog.models.some(entry => `${entry.name} ${entry.id} ${entry.ownedBy}`.toLowerCase().includes(query.toLowerCase())) && <p role="status" className="ai-settings-note">{t("검색 결과가 없습니다.")}</p>}
        <div className="dictation-model-list" role="group" aria-label={t("STT 모델")}>
          {catalog.models.filter(entry => `${entry.name} ${entry.id} ${entry.ownedBy}`.toLowerCase().includes(query.toLowerCase())).map(entry => <button key={entry.id} className="dictation-model" disabled={disabled || !entry.batchCompatible} aria-pressed={model === entry.id} onClick={() => onSelect(entry.id)}>
            <span className="dictation-model-heading"><strong>{entry.name}</strong>{model === entry.id && <Check size={14} />}</span>
            <span className="dictation-model-id">{entry.id}{entry.ownedBy && ` · ${entry.ownedBy}`}</span>
            {entry.description && <span className="dictation-model-description">{entry.description}</span>}
            <span>{entry.unavailableReason ? t(entry.unavailableReason) : modelPrice(entry)}</span>
          </button>)}
        </div>
        {model && !catalog.models.some(entry => entry.id === model && entry.batchCompatible) && <p className="dictation-notice">{t("선택한 모델은 현재 목록에서 파일 전사 지원을 확인하지 못했습니다.")}</p>}
      </>}
      {model && <p className="dictation-notice">{t("선택한 모델")}: <code>{model}</code></p>}
      <details className="dictation-advanced"><summary>{t("모델 ID 직접 입력")}</summary>
        <p className="dictation-notice">{t("직접 입력한 ID의 지원 여부는 제공자 문서에서 확인하세요.")}</p>
        <label className="dictation-field">{t("STT 모델")}<input disabled={disabled} value={manualModel} onChange={event => setManualModel(event.target.value)} placeholder={t("파일 전사 모델 ID")} /></label>
        <button className="settings-toolbar-button" disabled={disabled || !manualModel.trim()} onClick={() => onSelect(manualModel.trim())}>{t("이 모델 사용")}</button>
      </details>
    </>}
  </div>;
}
