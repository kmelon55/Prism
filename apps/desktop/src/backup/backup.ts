import { invoke } from "@tauri-apps/api/core";
import { normalizeBackgroundBlur } from "../settings/appearance";
import type { SettingsPreferences } from "../settings/SettingsView";

export type SafePreferences = Pick<SettingsPreferences, "language" | "theme" | "reduceMotion" | "backgroundOpacity" | "backgroundBlur" | "showApplicationIcons" | "commandAliases">;
export interface BackupCategories { snippets: boolean; quicklinks: boolean; pathLinks: boolean; favorites: boolean; preferences: boolean }
export interface BackupCounts { total: number; added: number; conflicts: number; skipped: number }
export interface BackupSummary { snippets: BackupCounts; quicklinks: BackupCounts; pathLinks: BackupCounts; favorites: BackupCounts }
export interface BackupPathReference { id: string; title: string; path: string; status: "existing" | "missing" | "unavailable"; conflict: boolean }
export interface BackupReview { token: string; summary: BackupSummary; pathReferences: BackupPathReference[]; missingFavorites: { id: string; title: string }[]; preferences: SafePreferences | null }
export const defaultCategories: BackupCategories = { snippets: true, quicklinks: true, pathLinks: false, favorites: true, preferences: false };
const safeKeys = ["language", "theme", "reduceMotion", "backgroundOpacity", "backgroundBlur", "showApplicationIcons", "commandAliases"] as const;
const byteLength = (value: string) => new TextEncoder().encode(value).length;
const safeId = (id: string) => id.length > 0 && byteLength(id) <= 512 && !/[\p{Cc}]/u.test(id) && !["__proto__", "prototype", "constructor"].includes(id);

/** Reject additional fields instead of allowing a future broad settings spread. */
export function validateSafePreferences(value: unknown): SafePreferences {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("This backup is invalid or unsupported.");
  const candidate = value as Record<string, unknown>;
  if (Object.keys(candidate).length !== safeKeys.length || Object.keys(candidate).some(key => !safeKeys.includes(key as typeof safeKeys[number]))
    || typeof candidate.language !== "string" || !["system", "en", "ko"].includes(candidate.language) || typeof candidate.theme !== "string" || !["system", "dark", "light"].includes(candidate.theme)
    || typeof candidate.reduceMotion !== "boolean" || typeof candidate.showApplicationIcons !== "boolean"
    || typeof candidate.backgroundOpacity !== "number" || !Number.isFinite(candidate.backgroundOpacity) || candidate.backgroundOpacity < 10 || candidate.backgroundOpacity > 100
    || typeof candidate.backgroundBlur !== "number" || !Number.isFinite(candidate.backgroundBlur) || candidate.backgroundBlur < 0 || candidate.backgroundBlur > 240
    || !candidate.commandAliases || typeof candidate.commandAliases !== "object" || Array.isArray(candidate.commandAliases)) throw new Error("This backup is invalid or unsupported.");
  const aliases = Object.entries(candidate.commandAliases);
  if (aliases.length > 1000 || aliases.some(([id, alias]) => !safeId(id) || typeof alias !== "string" || !alias.trim() || alias.length > 80 || /[\p{Cc}]/u.test(alias))) throw new Error("This backup is invalid or unsupported.");
  return { language: candidate.language as SafePreferences["language"], theme: candidate.theme as SafePreferences["theme"], reduceMotion: candidate.reduceMotion,
    backgroundOpacity: candidate.backgroundOpacity, backgroundBlur: candidate.backgroundBlur, showApplicationIcons: candidate.showApplicationIcons,
    commandAliases: Object.fromEntries(aliases) as Record<string, string> };
}
export function safePreferences(preferences: SettingsPreferences): SafePreferences {
  return validateSafePreferences(Object.fromEntries(safeKeys.map(key => [key, preferences[key]])));
}
const aliasKey = (value: string) => value.normalize("NFKC").trim().toLowerCase();
/** Preserve current aliases on ID or normalized-value collisions and every unsafe setting. */
export function mergeSafePreferences<T extends SettingsPreferences>(current: T, incoming: SafePreferences): T {
  const safe = validateSafePreferences(incoming);
  const commandAliases = { ...current.commandAliases };
  const values = new Set(Object.values(commandAliases).map(aliasKey));
  let count = Object.keys(commandAliases).length;
  for (const [id, alias] of Object.entries(safe.commandAliases)) {
    if (count >= 1000 || Object.hasOwn(commandAliases, id) || values.has(aliasKey(alias))) continue;
    commandAliases[id] = alias;
    values.add(aliasKey(alias)); count++;
  }
  // Continue accepting legacy backups up to 240, but only apply the current range.
  return { ...current, ...safe, backgroundBlur: normalizeBackgroundBlur(safe.backgroundBlur), commandAliases };
}
export function exportBackup(categories: BackupCategories, preferences: SettingsPreferences): Promise<boolean> {
  return invoke("backup_export", { categories, preferences: categories.preferences ? safePreferences(preferences) : null });
}
export async function previewBackup(categories: BackupCategories): Promise<BackupReview | null> {
  const review = await invoke<BackupReview | null>("backup_preview_import", { categories });
  if (review?.preferences) review.preferences = validateSafePreferences(review.preferences);
  return review;
}
export function applyBackup(token: string): Promise<BackupSummary> { return invoke("backup_apply_import", { token }); }

export function previewPreferenceAliases(current: SettingsPreferences, incoming: SafePreferences): { total: number; added: number; kept: number } {
  const merged = mergeSafePreferences(current, incoming);
  const total = Object.keys(incoming.commandAliases).length;
  const added = Object.keys(merged.commandAliases).length - Object.keys(current.commandAliases).length;
  return { total, added, kept: total - added };
}

export interface AliasReviewItem { id: string; alias: string; status: "add" | "id-conflict" | "value-conflict" | "capacity"; existingAlias?: string }
/** Explain every skipped alias using exactly the same conservative merge policy. */
export function reviewPreferenceAliases(current: SettingsPreferences, incoming: SafePreferences): AliasReviewItem[] {
  const safe = validateSafePreferences(incoming);
  const aliases = { ...current.commandAliases };
  const values = new Set(Object.values(aliases).map(aliasKey));
  let count = Object.keys(aliases).length;
  return Object.entries(safe.commandAliases).map(([id, alias]) => {
    if (Object.hasOwn(aliases, id)) return { id, alias, status: "id-conflict", existingAlias: aliases[id] };
    if (values.has(aliasKey(alias))) return { id, alias, status: "value-conflict" };
    if (count >= 1000) return { id, alias, status: "capacity" };
    aliases[id] = alias; values.add(aliasKey(alias)); count++;
    return { id, alias, status: "add" };
  });
}
