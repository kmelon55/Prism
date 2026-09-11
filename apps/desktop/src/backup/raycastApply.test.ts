import { beforeEach, expect, it, vi } from "vitest";
import { applyRaycastItems, undoRaycastImport, type AliasAccess, type MigrationJournal } from "./raycastApply";
import type { ImportItem } from "./raycastPlan";
import { buildRaycastPlan } from "./raycastPlan";
const state = vi.hoisted(() => ({ shortcuts: {} as Record<string, string>, entries: [] as unknown[], failJournal: false, failShortcut: false, calls: [] as string[] }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(async (command: string, args: any) => {
  state.calls.push(command);
  if (command === "raycast_write_journal" && state.failJournal) throw new Error("disk full");
  if (command === "library_save_entry") state.entries.push(args.entry);
  if (command === "library_delete_entry") state.entries = state.entries.filter((entry: any) => entry.id !== args.id);
}) }));
vi.mock("../providers/native", () => ({
  getCommandShortcuts: async () => Object.entries(state.shortcuts).map(([commandId, accelerator]) => ({ commandId, accelerator })),
  setCommandShortcut: async (id: string, shortcut: string) => { if (state.failShortcut) throw new Error("registration conflict"); state.shortcuts[id] = shortcut; },
  removeCommandShortcut: async (id: string) => { delete state.shortcuts[id]; },
}));
vi.mock("../providers/shortcut", () => ({ getGlobalShortcut: async () => ({ accelerator: "Alt+Space" }), setGlobalShortcut: vi.fn() }));
vi.mock("../providers/library", () => ({ loadLibrary: async () => ({ entries: state.entries, favorites: [] }) }));
let aliases: Record<string, string>;
const access: AliasAccess = { read: () => aliases, write: async next => { aliases = next; }, disabled: () => [] };
const hotkey: ImportItem = { id: "1", category: "hotkeys", title: "Left Half", commandId: "window:left-half", value: "Control+Alt+Left" };
beforeEach(() => { aliases = {}; state.shortcuts = {}; state.entries = []; state.failJournal = false; state.failShortcut = false; state.calls = []; });
it("imports and undoes power shortcuts and aliases without executing them", async () => {
  const rows = buildRaycastPlan({ settings: { commands: [{ id: "c:r:system::*::restart", alias: "reboot", hotkey: "control-option-0" }] } }, { apps: [], entries: [], aliases: {}, hotkeys: {}, disabled: [], platform: "macos" });
  const journal = await applyRaycastItems(rows, access, () => {});
  expect(state.shortcuts["system:restart"]).toBe("Control+Alt+A");
  expect(aliases["system:restart"]).toBe("reboot");
  expect(journal.changes.every(change => change.state === "applied")).toBe(true);
  expect(state.calls).not.toContain("run_system_action");
  await undoRaycastImport(journal, access, () => {});
  expect(state.shortcuts).toEqual({});
  expect(aliases).toEqual({});
});
it("aborts before mutation if the recovery copy cannot be saved", async () => {
  state.failJournal = true;
  await expect(applyRaycastItems([hotkey], access, () => {})).rejects.toThrow("disk full");
  expect(state.shortcuts).toEqual({});
});
it("does not overwrite a shortcut changed since the preview", async () => {
  state.shortcuts[hotkey.commandId!] = "Super+J";
  const journal = await applyRaycastItems([{ ...hotkey, before: "Super+K" }], access, () => {});
  expect(journal.changes[0].state).toBe("failed");
  expect(state.shortcuts[hotkey.commandId!]).toBe("Super+J");
});
it("reports registration failure and still imports the other selected items", async () => {
  state.failShortcut = true;
  const journal = await applyRaycastItems([hotkey, { id: "2", category: "aliases", title: "Right Half", commandId: "window:right-half", value: "right" }], access, () => {});
  expect(journal.changes.map(change => change.state)).toEqual(["failed", "applied"]);
  expect(aliases).toEqual({ "window:right-half": "right" });
  expect(state.calls[0]).toBe("raycast_write_journal");
});
it("undoes additions and replacements but preserves subsequent edits", async () => {
  state.shortcuts[hotkey.commandId!] = "Super+K";
  const journal = await applyRaycastItems([{ ...hotkey, before: "Super+K" }, { id: "2", category: "aliases", title: "Right", commandId: "window:right-half", value: "right" }], access, () => {});
  aliases["window:right-half"] = "new-alias";
  await undoRaycastImport(journal, access, () => {});
  expect(state.shortcuts[hotkey.commandId!]).toBe("Super+K");
  expect(aliases["window:right-half"]).toBe("new-alias");
  expect(journal.changes[1].error).toContain("kept");
});
it("recovers a write interrupted before the applied marker was saved", async () => {
  state.shortcuts[hotkey.commandId!] = hotkey.value;
  const journal: MigrationJournal = { version: 1, id: crypto.randomUUID(), changes: [{ item: hotkey, state: "pending" }] };
  await undoRaycastImport(journal, access, () => {});
  expect(state.shortcuts).toEqual({});
  expect(journal.changes[0].state).toBe("undone");
});
