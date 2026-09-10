import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { isTauriRuntime } from "./native";

export type AiProvider = "vercel" | "openai" | "openrouter";
export interface AiSelection { provider: AiProvider; model: string; modelName?: string | null }
export interface AiModel { supportsTools?: boolean | null; maxOutputTokens?: number | null; id: string; name: string; contextWindow: number | null; inputPrice?: number | null; outputPrice?: number | null; pricingVariable?: boolean }
export interface AiKeyInfo { configured: boolean; maskedKey: string | null; unlocked?: boolean }
export const aiProviders: Record<AiProvider, { name: string; description: string; keyUrl: string }> = {
  vercel: { name: "Vercel AI Gateway", get description() { return t("Gateway 키 하나로 여러 회사의 모델 사용"); }, keyUrl: "https://vercel.com/d?title=AI+Gateway+API+Keys&to=%2F%5Bteam%5D%2F~%2Fai-gateway%2Fapi-keys" },
  openai: { name: "OpenAI", get description() { return t("OpenAI 계정으로 직접 연결"); }, keyUrl: "https://platform.openai.com/api-keys" },
  openrouter: { name: "OpenRouter", get description() { return t("OpenRouter 키 하나로 여러 회사의 모델 사용"); }, keyUrl: "https://openrouter.ai/settings/keys" },
};
export const aiSelectionKey = "prism.ai.selection.v1";
const changeEvent = "prism:ai-settings-changed";
export function readAiSelection(): AiSelection {
  try {
    const value = JSON.parse(localStorage.getItem(aiSelectionKey) ?? "null");
    if (["vercel", "openai", "openrouter"].includes(value?.provider) && typeof value.model === "string" && value.model.length <= 200) {
      return { provider: value.provider, model: value.model, ...(typeof value.modelName === "string" ? { modelName: value.modelName } : {}) };
    }
  } catch { /* Optional preference; credentials live in Keychain. */ }
  return { provider: "vercel", model: "" };
}
export function notifyAiSettingsChanged() {
  window.dispatchEvent(new Event(changeEvent));
  if (isTauriRuntime()) void emit(changeEvent).catch(() => { /* Storage/focus recheck also synchronizes windows. */ });
}
function cacheSelection(selection: AiSelection) {
  try { localStorage.setItem(aiSelectionKey, JSON.stringify(selection)); } catch { /* Native storage remains authoritative. */ }
}
export async function loadAiSelection(nativeRuntime = isTauriRuntime()): Promise<AiSelection> {
  const legacy = readAiSelection();
  if (!nativeRuntime) return legacy;
  const saved = await invoke<AiSelection | null>("ai_get_selection", { legacy: legacy.model ? legacy : null });
  if (saved != null && (!aiProviders[saved.provider] || typeof saved.model !== "string")) throw t("저장된 AI 설정을 읽지 못했습니다.");
  const selection = saved ?? { provider: "vercel", model: "" };
  cacheSelection(selection);
  return selection;
}
export async function saveAiSelection(selection: AiSelection, nativeRuntime = isTauriRuntime()) {
  const saved = nativeRuntime ? await invoke<AiSelection>("ai_set_selection", { selection }) : selection;
  if (!saved || saved.provider !== selection.provider || saved.model !== selection.model) throw t("모델 선택 저장을 확인하지 못했습니다.");
  cacheSelection(saved);
  notifyAiSettingsChanged();
  return saved;
}
export function formatAiPrice(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value) || value < 0) return t("미제공");
  if (value === 0) return "$0";
  if (value < 0.0001) return "<$0.0001";
  return `$${new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 }).format(value)}`;
}
export function watchAiSettings(callback: () => void): () => void {
  const storage = (event: StorageEvent) => { if (event.key === aiSelectionKey || event.key === null) callback(); };
  window.addEventListener(changeEvent, callback);
  window.addEventListener("storage", storage);
  window.addEventListener("focus", callback);
  let disposed = false;
  let unlisten: (() => void) | undefined;
  if (isTauriRuntime()) void listen(changeEvent, callback).then((stop) => {
    if (disposed) stop(); else unlisten = stop;
  }).catch(() => {});
  return () => {
    disposed = true; unlisten?.();
    window.removeEventListener(changeEvent, callback);
    window.removeEventListener("storage", storage);
    window.removeEventListener("focus", callback);
  };
}
export const listAiModels = (provider: AiProvider) => invoke<AiModel[]>("ai_list_models", { provider });
export const aiErrorText = (error: unknown) => typeof error === "string" ? t(error) : t("작업을 완료하지 못했습니다. 다시 시도하세요.");
