import { describe, expect, it, vi } from "vitest";
import { applyBackup, defaultCategories, exportBackup, mergeSafePreferences, safePreferences, validateSafePreferences, reviewPreferenceAliases } from "./backup";
import type { SettingsPreferences } from "../settings/SettingsView";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
export const fixturePreferences: SettingsPreferences = {
  language: "en", theme: "dark", reduceMotion: false, backgroundOpacity: 97, backgroundBlur: 44, showApplicationIcons: true,
  commandAliases: { "prism:settings": "settings" }, disabledCommandIds: ["dangerous"], scriptDirectories: ["/existing/scripts"],
};
describe("safe backup preferences", () => {
  it("accepts legacy blur in backups but clamps it when restoring preferences", () => {
    for (const blur of [0, 12, 32, 44, 240]) {
      const incoming = safePreferences({ ...fixturePreferences, backgroundBlur: blur });
      expect(mergeSafePreferences(fixturePreferences, incoming).backgroundBlur).toBe(Math.min(32, blur));
    }
  });
  it("round-trips transparent glass preferences within the supported bounds", () => {
    for (const opacity of [10, 40, 64, 100]) {
      const preferences = { ...fixturePreferences, backgroundOpacity: opacity };
      expect(validateSafePreferences(safePreferences(preferences)).backgroundOpacity).toBe(opacity);
    }
    for (const opacity of [9, 101]) {
      expect(() => safePreferences({ ...fixturePreferences, backgroundOpacity: opacity })).toThrow();
    }
    for (const blur of [0, 60, 120, 180, 240]) {
      expect(validateSafePreferences(safePreferences({ ...fixturePreferences, backgroundBlur: blur })).backgroundBlur).toBe(blur);
    }
    for (const blur of [-1, 241]) {
      expect(() => safePreferences({ ...fixturePreferences, backgroundBlur: blur })).toThrow();
    }
  });
  it("exports only the explicit safe allowlist, never execution configuration", async () => {
    const preferences = { ...fixturePreferences, apiKey: "fixture-only", clipboardHistory: ["fixture"], hotkeys: { example: "Super+Q" } };
    expect(Object.keys(safePreferences(preferences)).sort()).toEqual(["language", "theme", "reduceMotion", "backgroundOpacity", "backgroundBlur", "showApplicationIcons", "commandAliases"].sort());
    await exportBackup({ ...defaultCategories, preferences: true }, preferences);
    expect(invoke).toHaveBeenLastCalledWith("backup_export", { categories: { ...defaultCategories, preferences: true }, preferences: safePreferences(preferences) });
    await exportBackup(defaultCategories, preferences);
    expect(invoke).toHaveBeenLastCalledWith("backup_export", { categories: defaultCategories, preferences: null });
  });
  it("rejects broad preferences, malformed ranges, unknown language and prototype aliases", () => {
    const safe = safePreferences(fixturePreferences);
    for (const value of [fixturePreferences, { ...safe, language: "fr" }, { ...safe, backgroundOpacity: 0 }, { ...safe, backgroundBlur: NaN }, { ...safe, commandAliases: JSON.parse('{"__proto__":"bad"}') }, { ...safe, commandAliases: { "app:one": "가".repeat(81) } }]) {
      expect(() => validateSafePreferences(value)).toThrow("invalid or unsupported");
    }
  });
  it("preserves full Korean aliases within the existing 80-character settings limit", () => {
    const safe = { ...safePreferences(fixturePreferences), commandAliases: { "native:fixture": "가".repeat(80) } };
    expect(validateSafePreferences(safe).commandAliases["native:fixture"]).toBe("가".repeat(80));
  });
  it("conservatively merges aliases while retaining current permissions and execution settings", () => {
    const current = { ...fixturePreferences, permissionGrants: ["fixture-root"], hotkeys: { fixture: "Super+G" } };
    const incoming = { ...safePreferences(fixturePreferences), theme: "light" as const, language: "ko" as const,
      commandAliases: { "prism:settings": "changed", "app:collision": "ＳＥＴＴＩＮＧＳ", "app:new": "새 앱" } };
    const next = mergeSafePreferences(current, incoming);
    expect(next.theme).toBe("light"); expect(next.language).toBe("ko");
    expect(next.commandAliases).toEqual({ "prism:settings": "settings", "app:new": "새 앱" });
    expect(next.scriptDirectories).toBe(current.scriptDirectories); expect(next.disabledCommandIds).toBe(current.disabledCommandIds);
    expect(next.permissionGrants).toBe(current.permissionGrants); expect(next.hotkeys).toBe(current.hotkeys);
    expect(current.commandAliases).toEqual({ "prism:settings": "settings" });
  });
  it("explains alias ID, normalized value, and capacity conflicts consistently with merge", () => {
    const incoming = { ...safePreferences(fixturePreferences), commandAliases: { "prism:settings": "changed", "app:collision": "ＳＥＴＴＩＮＧＳ", "app:new": "new", "app:duplicate": "NEW" } };
    expect(reviewPreferenceAliases(fixturePreferences, incoming).map(item => item.status)).toEqual(["id-conflict", "value-conflict", "add", "value-conflict"]);
    const full = { ...fixturePreferences, commandAliases: Object.fromEntries(Array.from({ length: 1000 }, (_, i) => [`app:${i}`, `alias${i}`])) };
    expect(reviewPreferenceAliases(full, { ...incoming, commandAliases: { "app:extra": "extra" } })[0].status).toBe("capacity");
    expect(Object.keys(mergeSafePreferences(full, incoming).commandAliases)).toHaveLength(1000);
  });
  it("applies only the reviewed token and never sends paths or document contents", async () => {
    await applyBackup("reviewed-token");
    expect(invoke).toHaveBeenLastCalledWith("backup_apply_import", { token: "reviewed-token" });
  });
});
