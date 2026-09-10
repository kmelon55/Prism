import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BackupSettings } from "./BackupSettings";
import type { BackupReview } from "./backup";
import type { SettingsPreferences } from "../settings/SettingsView";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
let root: Root, container: HTMLDivElement;
let review: BackupReview;
const restore = vi.fn();
const preferences: SettingsPreferences = { language: "en", theme: "dark", reduceMotion: false, backgroundOpacity: 97, backgroundBlur: 44, showApplicationIcons: true, commandAliases: {}, disabledCommandIds: [], scriptDirectories: [] };
beforeEach(() => {
  vi.clearAllMocks(); localStorage.setItem("prism:preferences", JSON.stringify({ language: "en" }));
  review = { token: "first-token", pathReferences: [], missingFavorites: [], summary: { snippets: { total: 3, added: 1, conflicts: 2, skipped: 0 }, quicklinks: { total: 0, added: 0, conflicts: 0, skipped: 0 }, pathLinks: { total: 0, added: 0, conflicts: 0, skipped: 0 }, favorites: { total: 1, added: 0, conflicts: 0, skipped: 1 } }, preferences: null };
  invoke.mockImplementation(async command => command === "backup_preview_import" ? structuredClone(review) : command === "backup_export" ? true : review.summary);
  restore.mockResolvedValue(undefined);
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount(nativeRuntime = true) { await act(async () => root.render(<StrictMode><BackupSettings nativeRuntime={nativeRuntime} preferences={preferences} onRestorePreferences={restore}/></StrictMode>)); }
function button(label: string) { const button = [...container.querySelectorAll("button")].find(button => button.textContent?.trim() === label); expect(button, label).toBeDefined(); return button!; }
async function click(label: string) { await act(async () => button(label).click()); }
async function toggle(label: string) { const input = [...container.querySelectorAll("label")].find(item => item.textContent === label)?.querySelector("input"); expect(input).toBeDefined(); await act(async () => input!.click()); }

describe("backup review lifecycle", () => {
  it("shows category conflict counts and requires explicit import after chooser review", async () => {
    await mount(); expect(invoke).not.toHaveBeenCalled(); await click("Choose backup to review");
    expect(container.querySelector("table")?.textContent).toContain("Conflicts kept");
    expect(container.querySelector("tbody tr")?.textContent).toBe("Snippets3120");
    expect(document.activeElement).toBe(container.querySelector("h3"));
    expect(invoke).toHaveBeenCalledTimes(1); expect(restore).not.toHaveBeenCalled();
    await click("Import new library items");
    expect(invoke).toHaveBeenLastCalledWith("backup_apply_import", { token: "first-token" });
    expect(button("Library restored").disabled).toBe(true);
  });
  it("invalidates preview after category changes and treats chooser cancellation as no mutation", async () => {
    await mount(); await click("Choose backup to review"); await toggle("Favorites");
    expect(container.querySelector("table")).toBeNull();
    invoke.mockResolvedValueOnce(null); await click("Choose backup to review");
    expect(container.querySelector("table")).toBeNull();
    expect(invoke.mock.calls.every(([command]) => command === "backup_preview_import")).toBe(true);
  });
  it("does not replay a failed import and requires a fresh review before retry", async () => {
    await mount(); await click("Choose backup to review"); invoke.mockRejectedValueOnce("Disk full");
    await click("Import new library items"); expect(container.querySelector("table")).toBeNull();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Disk full");
    review.token = "new-token"; await click("Review file again");
    expect(invoke.mock.calls.filter(([command]) => command === "backup_apply_import")).toHaveLength(1);
    await click("Import new library items"); expect(invoke).toHaveBeenLastCalledWith("backup_apply_import", { token: "new-token" });
  });
  it("keeps successful library import independent of failed preferences restore", async () => {
    const { scriptDirectories: _script, disabledCommandIds: _disabled, ...safe } = preferences;
    review.preferences = { ...safe, language: "ko" };
    await mount(); await toggle("Safe preferences"); await click("Choose backup to review");
    await click("Import new library items"); expect(restore).not.toHaveBeenCalled();
    restore.mockRejectedValueOnce(new Error("Preferences storage unavailable"));
    await click("Restore appearance, language, and aliases");
    expect(button("Library restored").disabled).toBe(true);
    await click("Retry preferences restore"); expect(restore).toHaveBeenCalledTimes(2);
    expect(invoke.mock.calls.filter(([command]) => command === "backup_apply_import")).toHaveLength(1);
    expect(button("Safe preferences restored").disabled).toBe(true);
  });
  it("retries export through the chooser without importing or restoring settings", async () => {
    invoke.mockRejectedValueOnce("The backup could not be saved. The existing file was preserved.");
    await mount(); await click("Export backup"); await click("Retry export");
    expect(invoke.mock.calls.map(([command]) => command)).toEqual(["backup_export", "backup_export"]);
    expect(container.querySelector('[role="status"]')?.textContent).toBe("Backup saved."); expect(restore).not.toHaveBeenCalled();
  });
  it("blocks rapid duplicate apply attempts while a native operation is pending", async () => {
    await mount(); await click("Choose backup to review"); let resolve!: (value: unknown) => void;
    invoke.mockImplementationOnce(() => new Promise(done => { resolve = done; }));
    await act(async () => { button("Import new library items").click(); button("Import new library items").click(); });
    expect(invoke.mock.calls.filter(([command]) => command === "backup_apply_import")).toHaveLength(1);
    await act(async () => resolve(review.summary));
  });
  it("renders native-only boundaries and disables empty selections", async () => {
    await mount(false); expect([...container.querySelectorAll("button")].every(button => button.disabled)).toBe(true);
    expect(invoke).not.toHaveBeenCalled(); expect(container.textContent).toContain("desktop app");
    await mount(true); await toggle("Snippets"); await toggle("Quicklinks"); await toggle("Favorites");
    expect(button("Export backup").disabled).toBe(true); expect(button("Choose backup to review").disabled).toBe(true);
  });
  it("keeps path portability opt-in and shows missing targets and skipped favorite identities", async () => {
    review.pathReferences = [{ id: "path", title: "Saved folder", path: "/fixture/missing", status: "missing", conflict: false }];
    review.missingFavorites = [{ id: "library:gone", title: "Missing snippet" }];
    review.summary.pathLinks = { total: 1, added: 1, conflicts: 0, skipped: 0 };
    await mount();
    const pathInput = [...container.querySelectorAll("label")].find(item => item.textContent === "Path references")!.querySelector("input")!;
    expect(pathInput.checked).toBe(false);
    await toggle("Path references"); await click("Choose backup to review");
    expect(invoke).toHaveBeenLastCalledWith("backup_preview_import", { categories: expect.objectContaining({ pathLinks: true }) });
    expect(container.textContent).toContain("Target missing"); expect(container.textContent).toContain("/fixture/missing"); expect(container.textContent).toContain("library:gone");
    expect(invoke.mock.calls.every(([command]) => command === "backup_preview_import")).toBe(true);
  });
  it("shows malformed and oversized file errors without making any mutation", async () => {
    await mount(); invoke.mockRejectedValueOnce("Backup files must be 20 MB or smaller."); await click("Choose backup to review");
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("20 MB");
    invoke.mockRejectedValueOnce("This backup is invalid or unsupported."); await click("Review file again");
    expect(container.querySelector("table")).toBeNull(); expect(restore).not.toHaveBeenCalled();
    expect(invoke.mock.calls.every(([command]) => command === "backup_preview_import")).toBe(true);
  });
});
