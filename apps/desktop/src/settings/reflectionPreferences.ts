import type { SettingsPreferences } from "./SettingsView";

// Keep preference normalization outside the component refresh boundary so the
// renderer and persistence always consume the same reflection fields.
export const reflectionDefaults = { reflectionIntensity: 65, reflectionEdge: 20, reflectionHighlight: 40, reflectionSpeed: 40 };

export function normalizeReflections(value: Partial<SettingsPreferences> | null) {
  const range = (key: keyof typeof reflectionDefaults, min: number, max: number) => {
    const number = value?.[key];
    return typeof number === "number" && Number.isFinite(number) ? Math.max(min, Math.min(max, number)) : reflectionDefaults[key];
  };
  return {
    openingLightAnimation: value?.openingLightAnimation !== false,
    reflectionIntensity: range("reflectionIntensity", 0, 100),
    reflectionEdge: range("reflectionEdge", 0, 100),
    reflectionHighlight: range("reflectionHighlight", 0, 100),
    reflectionSpeed: range("reflectionSpeed", 20, 80),
  };
}
