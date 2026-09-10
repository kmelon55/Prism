import { describe, expect, it, vi } from "vitest";
import { loadPreferences, persistPreferences, recoverPreferences, PREFERENCES_KEY, PREFERENCES_SNAPSHOT_KEY } from "./preferencesPersistence";
import type { SettingsPreferences } from "../settings/SettingsView";
const defaults: SettingsPreferences = { language: "en", theme: "system", reduceMotion: false, backgroundOpacity: 97, backgroundBlur: 44, showApplicationIcons: true, commandAliases: {}, scriptDirectories: [], disabledCommandIds: [] };
const normalize = (value: unknown) => ({ ...defaults, ...value as Partial<SettingsPreferences> });
function storage() {
  const values = new Map<string, string>();
  return { values, getItem: vi.fn((key: string) => values.get(key) ?? null), setItem: vi.fn((key: string, value: string) => { values.set(key, value); }) };
}
describe("last-known-good preference recovery", () => {
  it("snapshots only allowlisted preferences and leaves malformed primary bytes untouched until explicit recovery", () => {
    const store = storage();
    persistPreferences(store, { ...defaults, language: "ko", theme: "dark", scriptDirectories: ["/private"], apiKey: "fixture-secret", hotkeys: { a: "Super+A" } });
    const snapshot = store.values.get(PREFERENCES_SNAPSHOT_KEY)!;
    expect(snapshot).not.toContain("fixture-secret"); expect(snapshot).not.toContain("/private"); expect(snapshot).not.toContain("hotkeys");
    store.values.set(PREFERENCES_KEY, "{broken"); store.setItem.mockClear();
    const loaded = loadPreferences(store, normalize, defaults);
    expect(loaded.status).toBe("malformed"); expect(loaded.preferences).toBe(defaults); expect(store.setItem).not.toHaveBeenCalled();
    expect(() => persistPreferences(store, defaults)).toThrow("malformed");
    expect(store.values.get(PREFERENCES_KEY)).toBe("{broken");
    const current = { ...defaults, scriptDirectories: ["/current"], disabledCommandIds: ["keep-disabled"] };
    const recovered = recoverPreferences(store, current, loaded.recovery!);
    expect(recovered.preferences.language).toBe("ko"); expect(recovered.preferences.theme).toBe("dark");
    expect(recovered.preferences.scriptDirectories).toEqual(["/current"]); expect(recovered.preferences.disabledCommandIds).toEqual(["keep-disabled"]);
    expect(() => recoverPreferences(store, current, loaded.recovery!)).toThrow("Review recovery again");
  });
  it("detects invalid types and ranges before permissive app normalization and accepts old partial settings", () => {
    const store = storage();
    for (const value of [[], null, { theme: "unknown" }, { reduceMotion: "false" }, { backgroundOpacity: 9 }, { commandAliases: [] }, { scriptDirectories: [1] }]) {
      store.values.set(PREFERENCES_KEY, JSON.stringify(value));
      expect(loadPreferences(store, normalize, defaults).status).toBe("malformed");
    }
    store.values.set(PREFERENCES_KEY, '{"language":"ko"}');
    expect(loadPreferences(store, normalize, defaults)).toMatchObject({ status: "ok", preferences: { language: "ko" } });
  });
  it("rejects unsafe or newer snapshots and never replaces them on read", () => {
    const store = storage(); store.values.set(PREFERENCES_KEY, "{");
    for (const value of [{ version: 2, preferences: {} }, { version: 1, preferences: { ...defaults, permissionGrants: ["/"] } }, { version: 1, preferences: {}, unexpected: true }]) {
      store.values.set(PREFERENCES_SNAPSHOT_KEY, JSON.stringify(value));
      expect(loadPreferences(store, normalize, defaults).recovery).toBeNull();
    }
    expect(store.setItem).not.toHaveBeenCalled();
  });
  it("rejects cross-window changes, changed snapshots and expired reviews without writing", () => {
    for (const changed of ["primary", "snapshot", "expired"]) {
      const store = storage(); persistPreferences(store, defaults); store.values.set(PREFERENCES_KEY, "{");
      const review = loadPreferences(store, normalize, defaults).recovery!;
      if (changed === "primary") store.values.set(PREFERENCES_KEY, JSON.stringify({ theme: "dark" }));
      if (changed === "snapshot") store.values.set(PREFERENCES_SNAPSHOT_KEY, "new snapshot");
      if (changed === "expired") vi.spyOn(Date, "now").mockReturnValue(review.created + 600001);
      store.setItem.mockClear();
      expect(() => recoverPreferences(store, defaults, review)).toThrow("Review recovery again"); expect(store.setItem).not.toHaveBeenCalled();
      vi.restoreAllMocks();
    }
  });
  it("preserves primary and snapshot on primary storage failure and consumes failed recovery reviews", () => {
    const store = storage(); persistPreferences(store, defaults); store.values.set(PREFERENCES_KEY, "{");
    const before = new Map(store.values); const review = loadPreferences(store, normalize, defaults).recovery!;
    store.setItem.mockImplementation(() => { throw new Error("quota"); });
    expect(() => recoverPreferences(store, defaults, review)).toThrow("quota"); expect(store.values).toEqual(before);
    expect(() => recoverPreferences(store, defaults, review)).toThrow("Review recovery again");
  });
  it("reports snapshot failure separately from successful primary persistence", () => {
    const store = storage();
    store.setItem.mockImplementation((key, value) => { if (key === PREFERENCES_SNAPSHOT_KEY) throw new Error("quota"); store.values.set(key, value); });
    expect(persistPreferences(store, defaults)).toEqual({ snapshotSaved: false });
    expect(JSON.parse(store.values.get(PREFERENCES_KEY)!)).toEqual(defaults);
  });
  it("treats unavailable storage as unavailable without writes", () => {
    const store = storage(); store.getItem.mockImplementation(() => { throw new Error("denied"); });
    expect(loadPreferences(store, normalize, defaults)).toMatchObject({ status: "unavailable", recovery: null }); expect(store.setItem).not.toHaveBeenCalled();
  });
});

describe("explicit reviewed backup preference replacement", () => {
  it("recovers without a snapshot, preserves original bytes, and rejects stale originals", async () => {
    const { restoreReviewedBackupPreferences, PREFERENCES_BEFORE_RECOVERY_KEY } = await import("./preferencesPersistence");
    const { safePreferences } = await import("./backup");
    const store = storage(); store.values.set(PREFERENCES_KEY, "{corrupt");
    const loaded = loadPreferences(store, normalize, defaults); expect(loaded.recovery).toBeNull();
    const incoming = { ...safePreferences(defaults), language: "ko" as const };
    const result = restoreReviewedBackupPreferences(store, defaults, incoming, loaded.original);
    expect(result.preferences.language).toBe("ko");
    expect(JSON.parse(store.values.get(PREFERENCES_BEFORE_RECOVERY_KEY)!).original).toBe("{corrupt");
    const before = new Map(store.values);
    expect(() => restoreReviewedBackupPreferences(store, defaults, incoming, loaded.original)).toThrow("Review recovery again");
    expect(store.values).toEqual(before);
  });
  it("aborts without replacing the corrupt primary when preservation fails", async () => {
    const { restoreReviewedBackupPreferences, PREFERENCES_BEFORE_RECOVERY_KEY } = await import("./preferencesPersistence");
    const { safePreferences } = await import("./backup");
    const store = storage(); store.values.set(PREFERENCES_KEY, "{");
    store.setItem.mockImplementation((key, value) => { if (key === PREFERENCES_BEFORE_RECOVERY_KEY) throw new Error("archive full"); store.values.set(key, value); });
    expect(() => restoreReviewedBackupPreferences(store, defaults, safePreferences(defaults), "{")).toThrow("archive full");
    expect(store.values.get(PREFERENCES_KEY)).toBe("{"); expect(store.values.has(PREFERENCES_SNAPSHOT_KEY)).toBe(false);
  });
});
