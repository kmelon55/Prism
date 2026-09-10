import type { SettingsPreferences } from "../settings/SettingsView";
import { DEFAULT_BACKGROUND_BLUR } from "../settings/appearance";
import { mergeSafePreferences, safePreferences, validateSafePreferences, type SafePreferences } from "./backup";

export const PREFERENCES_KEY = "prism:preferences";
export const PREFERENCES_BEFORE_RECOVERY_KEY = "prism:preferences:before-recovery:v1";
export const PREFERENCES_SNAPSHOT_KEY = "prism:preferences:last-known-good:v1";
type StorageAccess = Pick<Storage, "getItem" | "setItem">;
const MAX_SETTINGS_LENGTH = 1024 * 1024;
const CORRUPT = "Local settings are malformed. Review recovery before saving changes.";
const STALE = "Settings changed or recovery expired. Review recovery again.";
const usedReviews = new WeakSet<PreferencesRecoveryReview>();
export interface PreferencesRecoveryReview {
  readonly preferences: SafePreferences;
  readonly original: string | null;
  readonly snapshot: string;
  readonly created: number;
}
export interface PreferencesLoadResult<T> {
  preferences: T;
  status: "ok" | "missing" | "malformed" | "unavailable";
  recovery: PreferencesRecoveryReview | null;
  original: string | null;
}
/** Validate present fields before normalization can silently discard corruption; older partial settings remain valid. */
function parseSettings(raw: string): Record<string, unknown> {
  if (raw.length > MAX_SETTINGS_LENGTH) throw new Error(CORRUPT);
  const value: unknown = JSON.parse(raw);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(CORRUPT);
  const record = value as Record<string, unknown>;
  const base: SafePreferences = { language: "system", theme: "system", reduceMotion: false, backgroundOpacity: 64, backgroundBlur: DEFAULT_BACKGROUND_BLUR, showApplicationIcons: true, commandAliases: {} };
  for (const key of Object.keys(base) as (keyof SafePreferences)[]) if (Object.hasOwn(record, key)) Object.assign(base, { [key]: record[key] });
  validateSafePreferences(base);
  for (const key of ["disabledCommandIds", "scriptDirectories"]) {
    if (Object.hasOwn(record, key) && (!Array.isArray(record[key]) || (record[key] as unknown[]).some(item => typeof item !== "string"))) throw new Error(CORRUPT);
  }
  return record;
}
function parseSnapshot(raw: string): SafePreferences {
  if (raw.length > MAX_SETTINGS_LENGTH) throw new Error(CORRUPT);
  const value = JSON.parse(raw);
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length !== 2 || value.version !== 1 || !Object.hasOwn(value, "preferences")) throw new Error(CORRUPT);
  return validateSafePreferences(value.preferences);
}
/** Read-only: malformed bytes are preserved, defaults are temporary, recovery is never automatic. */
export function loadPreferences<T extends SettingsPreferences>(storage: StorageAccess, normalize: (value: unknown) => T, defaults: T): PreferencesLoadResult<T> {
  let raw: string | null;
  try { raw = storage.getItem(PREFERENCES_KEY); } catch { return { preferences: defaults, status: "unavailable", recovery: null, original: null }; }
  if (raw === null) return { preferences: defaults, status: "missing", recovery: null, original: null };
  try { return { preferences: normalize(parseSettings(raw)), status: "ok", recovery: null, original: raw }; } catch {
    let recovery: PreferencesRecoveryReview | null = null;
    try {
      const snapshot = storage.getItem(PREFERENCES_SNAPSHOT_KEY);
      if (snapshot !== null) recovery = { preferences: parseSnapshot(snapshot), original: raw, snapshot, created: Date.now() };
    } catch { /* An invalid snapshot must never become a recovery source. */ }
    return { preferences: defaults, status: "malformed", recovery, original: raw };
  }
}
function snapshotPreferences(storage: StorageAccess, preferences: SettingsPreferences): boolean {
  try { storage.setItem(PREFERENCES_SNAPSHOT_KEY, JSON.stringify({ version: 1, preferences: safePreferences(preferences) })); return true; } catch { return false; }
}
/** Persist before updating App state. A snapshot failure is reported separately from a successful primary write. */
export function persistPreferences<T extends SettingsPreferences>(storage: StorageAccess, preferences: T): { snapshotSaved: boolean } {
  const encoded = JSON.stringify(preferences);
  parseSettings(encoded);
  const existing = storage.getItem(PREFERENCES_KEY);
  if (existing !== null) { try { parseSettings(existing); } catch { throw new Error(CORRUPT); } }
  storage.setItem(PREFERENCES_KEY, encoded);
  return { snapshotSaved: snapshotPreferences(storage, preferences) };
}
/** Called only by the explicit restore action after showing the backup preferences.
 * expectedOriginal comes from loadPreferences, not a fresh read taken at the moment of replacement.
 * Archive failure aborts before replacing primary data; at most one previous primary is retained.
 */
export function restoreReviewedBackupPreferences<T extends SettingsPreferences>(storage: StorageAccess, current: T, incoming: SafePreferences, expectedOriginal: string | null): { preferences: T; snapshotSaved: boolean } {
  const next = mergeSafePreferences(current, incoming);
  const encoded = JSON.stringify(next);
  parseSettings(encoded);
  if (storage.getItem(PREFERENCES_KEY) !== expectedOriginal) throw new Error(STALE);
  if (expectedOriginal !== null) {
    if (expectedOriginal.length > MAX_SETTINGS_LENGTH) throw new Error("Stored settings are too large to preserve before recovery.");
    storage.setItem(PREFERENCES_BEFORE_RECOVERY_KEY, JSON.stringify({ version: 1, original: expectedOriginal }));
  }
  // Recheck after the preservation write as well. localStorage has no cross-window transaction.
  if (storage.getItem(PREFERENCES_KEY) !== expectedOriginal) throw new Error(STALE);
  storage.setItem(PREFERENCES_KEY, encoded);
  return { preferences: next, snapshotSaved: snapshotPreferences(storage, next) };
}
/** Explicit, bounded, single-use recovery; preserve current non-allowlisted settings and recheck both stored inputs. */
export function recoverPreferences<T extends SettingsPreferences>(storage: StorageAccess, current: T, review: PreferencesRecoveryReview): { preferences: T; snapshotSaved: boolean } {
  if (usedReviews.has(review)) throw new Error(STALE);
  usedReviews.add(review);
  if (Date.now() - review.created > 10 * 60 * 1000 || Date.now() < review.created
    || storage.getItem(PREFERENCES_KEY) !== review.original || storage.getItem(PREFERENCES_SNAPSHOT_KEY) !== review.snapshot) throw new Error(STALE);
  // Reparse the exact reviewed snapshot, never trust mutable renderer fields.
  return restoreReviewedBackupPreferences(storage, current, parseSnapshot(review.snapshot), review.original);
}
