import { t } from "../i18n";
import { formatAiPrice, type AiProvider } from "../providers/ai";

// Reference observations, not a prediction of Prism request latency.
// Source: https://vercel.com/ai-gateway/models/{slug}, 2026-10-28.
const speedReferences: Record<string, { tokens: number; first: number; route: string }> = {
  "google/gemini-2.5-flash-lite": { tokens: 477, first: 0.3, route: "Google Vertex AI" },
  "google/gemini-3.1-flash-lite": { tokens: 276, first: 0.7, route: "Google Vertex AI" },
  "mistral/mistral-nemo": { tokens: 42, first: 0.3, route: "DeepInfra" },
};

export function priceLevel(price: number | null | undefined): number | null {
  if (price == null || !Number.isFinite(price) || price < 0) return null;
  if (price === 0) return 0;
  return [0.1, 0.5, 2, 10].filter(bound => price >= bound).length + 1;
}

function Meter({ level, kind }: { level: number; kind: "price" | "speed" }) {
  return <span className={`model-meter model-meter-${kind}`} aria-hidden="true">{[1, 2, 3, 4, 5].map(index => <i key={index} data-filled={index <= level} />)}</span>;
}

export function ModelPrice({ price, variable }: { price?: number | null; variable?: boolean }) {
  const level = priceLevel(price);
  return <span className="model-metric" title={t("USD / 100만 토큰 · 가격 단계: $0 / <$0.1 / <$0.5 / <$2 / <$10 / $10+") + (variable ? t(" · 구간·경로에 따라 요금 변동") : "")}>
    <span>{level == null ? "—" : formatAiPrice(price)}{variable && level != null ? "*" : ""}</span>
    {level != null && <Meter level={level} kind="price" />}
  </span>;
}

export function ModelSpeed({ model, provider }: { model: string; provider: AiProvider }) {
  const reference = provider === "vercel" ? speedReferences[model] : undefined;
  return <span className="model-metric model-speed" title={reference
    ? `Vercel AI Gateway · ${reference.route} · 2026-10-28 · ${t("첫 토큰")} ${reference.first}s · ${t("실제 응답 시간은 요청과 경로에 따라 달라져요.")} · https://vercel.com/ai-gateway/models/${model.split("/")[1]}`
    : t("비교 가능한 공개 속도 자료가 없어요.")}>
    <span>{reference ? `${reference.tokens} t/s` : "—"}</span>
    {reference && <Meter level={[50, 100, 200, 400].filter(bound => reference.tokens >= bound).length + 1} kind="speed" />}
  </span>;
}

export type ModelSort = "name" | "input" | "output";
export function ModelColumns({ sort, onSort }: { sort: ModelSort; onSort(value: ModelSort): void }) {
  return <div className="model-catalog-columns">{(["name", "input", "output"] as const).map((key, index) =>
    <button type="button" key={key} aria-pressed={sort === key} onClick={() => onSort(key)}>{t(["모델", "입력", "출력"][index])}{sort === key ? " ↑" : ""}</button>)}<span>{t("참고 속도")}</span></div>;
}

export function ModelMetricLegend() {
  return <p className="model-metric-legend" title={t("USD / 100만 토큰 · 제공업체 API의 기본 요금입니다. * 구간·경로에 따라 요금 변동. 캐시 등 추가 조건은 별도입니다.")}>{t("USD / 100만 토큰 · 칸이 많을수록 높은 가격·빠른 생성 속도예요. — 정보 없음")}
    <span>{t("속도: Vercel 공개 자료 · 2026-10-28 · 실제 대기 시간과 달라요.")}</span></p>;
}
