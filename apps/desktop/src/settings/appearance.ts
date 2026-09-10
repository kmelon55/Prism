export const MAX_BACKGROUND_BLUR = 32;
export const DEFAULT_BACKGROUND_BLUR = 12;

export function normalizeBackgroundBlur(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.round(Math.min(MAX_BACKGROUND_BLUR, Math.max(0, value)))
    : DEFAULT_BACKGROUND_BLUR;
}
