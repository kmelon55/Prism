import { bilingual } from "../i18n";
import type { PreferencesSection } from "./SettingsView";

export interface SettingsTarget { id: string; section: PreferencesSection; label: string; control: string; keywords?: string[]; commandId?: string }
export const settingsTargets: SettingsTarget[] = [
  { id: "language", section: "general", label: "App language", control: "App language", keywords: ["language", "언어"] },
  { id: "theme", section: "general", label: "Theme", control: "Appearance", keywords: ["dark light system", "테마 다크 라이트"] },
  { id: "opacity", section: "general", label: "Background opacity", control: "Background opacity" },
  { id: "blur", section: "general", label: "Background blur", control: "Background blur" },
  { id: "highlights", section: "general", label: "Prism highlights", control: "Prism highlights" },
  { id: "icons", section: "general", label: "Show application icons", control: "Show application icons" },
  { id: "motion", section: "general", label: "Animations", control: "Animations", keywords: ["reduce motion", "동작 줄이기"] },
  { id: "retention", section: "clipboard", label: "Keep history for", control: "Keep history for", keywords: ["clipboard retention", "클립보드 보관 기간"] },
  { id: "clipboard", section: "clipboard", label: "Enable clipboard history", control: "Enable clipboard history" },
  { id: "cycle", section: "window-management", label: "Cycle window sizes", control: "Cycle window sizes" },
  { id: "gap", section: "window-management", label: "Window gap", control: "Window gap" },
  { id: "edge-gap", section: "window-management", label: "Screen edge gap", control: "Screen edge gap" },
  { id: "almost-maximize", section: "window-management", label: "Almost Maximize size", control: "Almost Maximize size" },
  { id: "ai-model", section: "ai", label: "Change AI model", control: "기본 모델 변경", keywords: ["model provider API", "모델 제공업체"] },
];
export function searchSettingsTargets(targets: SettingsTarget[], query: string): SettingsTarget[] {
  const normalize = (text: string) => text.normalize("NFKC").toLocaleLowerCase();
  const tokens = normalize(query).trim().split(/\s+/).filter(Boolean);
  if (!tokens.length) return [];
  return targets.filter(target => {
    const text = [target.label, ...(target.keywords ?? [])].flatMap(bilingual).map(normalize).join(" ");
    return tokens.every(token => text.includes(token));
  }).slice(0, 30);
}
