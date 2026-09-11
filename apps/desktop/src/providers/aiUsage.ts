import { invoke } from "@tauri-apps/api/core";
import { formatAiPrice } from "./ai";
import { t } from "../i18n";
export interface UsageTotals {
  requests: number; inputTokens: number; outputTokens: number; knownCostUsd: number;
  unknownCostRequests: number; unknownTokenRequests: number; estimatedRequests: number;
}
export interface UsageRow {
  id: number; startedAt: number; feature: string; provider: string; model: string; status: string;
  inputTokens: number | null; outputTokens: number | null; costUsd: number | null; costKind: string;
}
export interface UsageBreakdown extends UsageTotals { feature: string; provider: string; model: string }
export interface UsageDay extends UsageTotals { day: string }
export interface UsageSummary { breakdown: UsageBreakdown[]; daily: UsageDay[]; month: UsageTotals; allTime: UsageTotals; features: (UsageTotals & { feature: string })[]; recent: UsageRow[] }
export function loadUsage() {
  const now = new Date();
  return invoke<UsageSummary>("ai_usage_summary", { since: new Date(now.getFullYear(), now.getMonth(), 1).getTime() });
}
export function featureName(feature: string) {
  return t(({ transcription: "Transcription", cleanup: "Refine speech", prompt: "Structure prompt", chat: "AI Chat" } as Record<string, string>)[feature] ?? feature);
}
export function usageProviderName(provider: string) {
  return ({vercel:"Vercel AI Gateway",openai:"OpenAI",openrouter:"OpenRouter",groq:"Groq",xai:"xAI",local:t("Local"),custom:t("Custom")} as Record<string,string>)[provider] ?? provider;
}
export function usageCost(value: UsageTotals): string {
  if (!value.requests) return formatAiPrice(0);
  if (value.unknownCostRequests === value.requests) return t("Cost unavailable");
  return `${value.estimatedRequests ? "≈ " : ""}${formatAiPrice(value.knownCostUsd)}${value.unknownCostRequests ? " + ?" : ""}`;
}
export function rowCost(value: UsageRow) { return value.costUsd == null ? t("Cost unavailable") : `${value.costKind === "estimated" ? "≈ " : ""}${formatAiPrice(value.costUsd)}`; }

export const emptyUsageTotals: UsageTotals = {requests:0,inputTokens:0,outputTokens:0,knownCostUsd:0,unknownCostRequests:0,unknownTokenRequests:0,estimatedRequests:0};
export type UsageGrouping = "feature" | "model" | "provider";
export type UsageMetric = "cost" | "tokens" | "requests";
export function metricValue(totals: UsageTotals, metric: UsageMetric) { return metric === "cost" ? totals.knownCostUsd : metric === "tokens" ? totals.inputTokens + totals.outputTokens : totals.requests; }
export function groupUsage(rows: UsageBreakdown[], group: UsageGrouping, metric: UsageMetric) {
  const grouped = new Map<string, UsageTotals>();
  for (const row of rows) {
    const key = group === "model" ? `${row.provider} / ${row.model}` : row[group];
    const total = grouped.get(key) ?? {...emptyUsageTotals};
    for (const field of Object.keys(emptyUsageTotals) as (keyof UsageTotals)[]) total[field] += row[field];
    grouped.set(key,total);
  }
  return [...grouped].map(([name,totals]) => ({name,...totals})).sort((a,b)=>metricValue(b,metric)-metricValue(a,metric)||a.name.localeCompare(b.name));
}
export function monthDays(daily: UsageDay[], now = new Date()) {
  const known = new Map(daily.map(day => [day.day,day]));
  const count = new Date(now.getFullYear(),now.getMonth()+1,0).getDate();
  return Array.from({length:count},(_,index)=> {
    const date = new Date(now.getFullYear(),now.getMonth(),index+1);
    const day = `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}-${String(index+1).padStart(2,"0")}`;
    return {...emptyUsageTotals,...known.get(day),day,future:index+1>now.getDate()};
  });
}
