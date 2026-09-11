import { invoke } from "@tauri-apps/api/core";
import { getCommandShortcuts, setCommandShortcut, removeCommandShortcut } from "../providers/native";
import { getGlobalShortcut, setGlobalShortcut } from "../providers/shortcut";
import { loadLibrary } from "../providers/library";
import type { ImportItem } from "./raycastPlan";
import { canonicalHotkey } from "./raycastPlan";

export interface MigrationChange { item: ImportItem; before?: string; state: "pending" | "applied" | "failed" | "undone"; error?: string }
export interface MigrationJournal { version: 1; id: string; changes: MigrationChange[] }
export interface AliasAccess { read(): Record<string, string>; write(aliases: Record<string, string>): Promise<void>; disabled(): string[] }
let migrationInFlight = false;
async function exclusive<T>(operation: () => Promise<T>): Promise<T> {
  if (migrationInFlight) throw new Error("An import is already running.");
  migrationInFlight = true;
  try { return await operation(); } finally { migrationInFlight = false; }
}
export const applyRaycastItems = (items: ImportItem[], access: AliasAccess, onJournal: (journal: MigrationJournal) => void) => exclusive(() => applyItems(items, access, onJournal));
export const undoRaycastImport = (journal: MigrationJournal, access: AliasAccess, onJournal: (journal: MigrationJournal) => void) => exclusive(() => undoImport(journal, access, onJournal));
const errorText = (error: unknown) => error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String(error.message) : String(error);
export const readMigrationJournal = () => invoke<MigrationJournal | null>("raycast_read_journal");
const writeJournal = (journal: MigrationJournal, create = false) => invoke("raycast_write_journal", { journal, create });
export const clearMigrationJournal = (id: string) => invoke("raycast_clear_journal", { id });
async function hotkeys(): Promise<Record<string, string>> {
  const [commands, global] = await Promise.all([getCommandShortcuts(), getGlobalShortcut()]);
  return { ...Object.fromEntries(commands.map(command => [command.commandId, command.accelerator])), launcher: global.accelerator };
}
const sameEntry = (a: ImportItem["entry"], b: ImportItem["entry"]) => Boolean(a && b && a.kind === b.kind && a.title === b.title && a.value === b.value && (a.keyword || "") === (b.keyword || ""));
async function applyItems(items: ImportItem[], access: AliasAccess, onJournal: (journal: MigrationJournal) => void): Promise<MigrationJournal> {
  const journal: MigrationJournal = { version: 1, id: crypto.randomUUID(), changes: items.map(item => ({ item, before: item.before, state: "pending" })) };
  // Durability is a prerequisite; a failed backup causes zero data mutations.
  await writeJournal(journal, true); onJournal(structuredClone(journal));
  for (const change of journal.changes) {
    const item = change.item;
    try {
      if (item.commandId && access.disabled().includes(item.commandId)) throw new Error("Command is disabled in Prism");
      if (item.category === "hotkeys" && item.commandId) {
        const current = await hotkeys();
        if (current[item.commandId] !== change.before || Object.entries(current).some(([id, value]) => id !== item.commandId && canonicalHotkey(value) === canonicalHotkey(item.value))) throw new Error("Shortcut changed or is already in use");
        if (item.commandId === "launcher") await setGlobalShortcut(item.value);
        else await setCommandShortcut(item.commandId, item.value);
      } else if (item.category === "aliases" && item.commandId) {
        const current = access.read();
        const normalize = (value: string) => value.normalize("NFKC").trim().toLowerCase();
        if (current[item.commandId] !== change.before || Object.entries(current).some(([id, value]) => id !== item.commandId && normalize(value) === normalize(item.value))) throw new Error("Alias changed or is already in use");
        await access.write({ ...current, [item.commandId]: item.value });
      } else if (item.entry) {
        const current = await loadLibrary();
        if (current.entries.some(entry => entry.id === item.entry!.id || entry.kind === item.entry!.kind && (entry.title === item.entry!.title || entry.value === item.entry!.value || Boolean(item.entry!.keyword && entry.keyword === item.entry!.keyword)))) throw new Error("Existing item kept");
        await invoke("library_save_entry", { entry: item.entry });
      } else throw new Error("Invalid import item");
      change.state = "applied";
    } catch (error) { change.state = "failed"; change.error = errorText(error); }
    // Stop if recording progress fails. Pending records can still recover a write after a crash.
    await writeJournal(journal); onJournal(structuredClone(journal));
  }
  return journal;
}
/** Restore only values still matching this import, preserving subsequent user edits. */
async function undoImport(journal: MigrationJournal, access: AliasAccess, onJournal: (journal: MigrationJournal) => void): Promise<MigrationJournal> {
  for (const change of [...journal.changes].reverse()) {
    if (change.state === "undone" || change.state === "failed") continue;
    const item = change.item;
    try {
      if (item.category === "hotkeys" && item.commandId) {
        const current = (await hotkeys())[item.commandId];
        if (current === change.before) { change.state = "undone"; }
        else {
          if (!current || canonicalHotkey(current) !== canonicalHotkey(item.value)) throw new Error("Changed after import; kept");
          if (item.commandId === "launcher") { if (!change.before) throw new Error("Original launcher shortcut is missing"); await setGlobalShortcut(change.before); }
          else if (change.before) await setCommandShortcut(item.commandId, change.before);
          else await removeCommandShortcut(item.commandId);
          change.state = "undone";
        }
      } else if (item.category === "aliases" && item.commandId) {
        const current = access.read();
        if (current[item.commandId] !== change.before) {
          if (current[item.commandId] !== item.value) throw new Error("Changed after import; kept");
          const next = { ...current }; if (change.before === undefined) delete next[item.commandId]; else next[item.commandId] = change.before;
          await access.write(next);
        }
        change.state = "undone";
      } else if (item.entry) {
        const current = await loadLibrary(), existing = current.entries.find(entry => entry.id === item.entry!.id);
        if (existing) {
          if (!sameEntry(existing, item.entry) || current.favorites.some(favorite => favorite.id === `library:${item.entry!.id}`)) throw new Error("Changed after import; kept");
          await invoke("library_delete_entry", { id: item.entry.id });
        }
        change.state = "undone";
      }
      change.error = undefined;
    } catch (error) { change.error = errorText(error); }
    await writeJournal(journal); onJournal(structuredClone(journal));
  }
  return journal;
}
