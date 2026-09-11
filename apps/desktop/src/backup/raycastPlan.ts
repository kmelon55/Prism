import { record } from "./raycastFile";
import type { LibraryEntry } from "../providers/library";
import type { NativeApplication } from "../providers/native";
import { prismCommandDefinitions } from "../providers/prism";
import { systemCommandDefinitions, systemCommandIds, type SystemPlatform, type DesktopCapabilities } from "../providers/system";

export type ImportCategory = "hotkeys" | "aliases" | "snippets" | "quicklinks";
export interface ImportItem {
  id: string; category: ImportCategory; title: string; value: string;
  commandId?: string; before?: string; entry?: LibraryEntry; reason?: string; conflict?: boolean;
}
export interface ImportContext { apps: NativeApplication[]; entries: LibraryEntry[]; aliases: Record<string, string>; hotkeys: Record<string, string>; disabled: string[]; platform?: SystemPlatform; capabilities?: DesktopCapabilities }
const text = (value: unknown) => typeof value === "string" ? value : "";
const list = (value: unknown): unknown[] => Array.isArray(value) ? value : [];
const child = (value: unknown, key: string) => record(value)[key];
const safeName = (value: string) => value.length > 0 && !/[\p{Cc}]/u.test(value) && !["__proto__", "constructor", "prototype"].includes(value);
const byteLength = (value: string) => new TextEncoder().encode(value).length;
export function raycastApplicationPaths(data: unknown): string[] {
  const root = record(data);
  const commands = [...list(child(root.builtin_package_rootSearch, "rootSearch")), ...list(child(root.settings, "commands"))];
  if (commands.length > 3000) throw new Error("Too many import items.");
  return [...new Set(commands.flatMap(raw => {
    const item = record(raw), id = text(item.id);
    const path = text(item.path) || (id.startsWith("c:r:applications::*::application::=::") ? id.split("::=::")[1] : "");
    return path.endsWith(".app") && path.length <= 4096 ? [path] : [];
  }))];
}
// macOS virtual key codes, independent of display language.
const keys: Record<number, string> = Object.fromEntries([
  ...["A", "S", "D", "F", "H", "G", "Z", "X", "C", "V", "", "B", "Q", "W", "E", "R", "Y", "T", "1", "2", "3", "4", "6", "5", "Equal", "9", "7", "Minus", "8", "0", "BracketRight", "O", "U", "BracketLeft", "I", "P", "Enter", "L", "J", "Quote", "K", "Semicolon", "Backslash", "Comma", "Slash", "N", "M", "Period", "Tab", "Space", "Backquote", "Backspace"].map((key, code) => [code, key]),
  [53, "Escape"], [123, "Left"], [124, "Right"], [125, "Down"], [126, "Up"], [115, "Home"], [119, "End"], [116, "PageUp"], [121, "PageDown"], [117, "Delete"],
  ...[122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].map((code, index) => [code, `F${index + 1}`]),
]);
const modifiers: Record<string, string> = { command: "Super", cmd: "Super", meta: "Super", super: "Super", control: "Control", ctrl: "Control", alt: "Alt", option: "Alt", shift: "Shift" };
export function canonicalHotkey(value: string): string {
  const parts = value.split("+"); const key = parts.pop() ?? "";
  const flags = new Set(parts.map(part => modifiers[part.toLowerCase()] ?? part));
  return [...["Control", "Alt", "Shift", "Super"].filter(part => flags.has(part)), key.toLowerCase()].join("+");
}
export function raycastHotkey(value: unknown): string | undefined {
  let code: unknown, mods: unknown[];
  if (typeof value === "string") {
    const parts = value.split("-"); code = Number(parts.pop()); mods = parts;
  } else {
    const kind = record(record(value).kind), shortcut = record(kind.shortcut), key = record(shortcut.key);
    if (kind.type !== "SingleStep" || key.type !== "LayoutIndependent") return;
    code = key.code; mods = list(shortcut.modifiers).map(mod => child(mod, "modifier"));
  }
  if (typeof code !== "number" || !keys[code] || !mods.length) return;
  const flags = new Set<string>();
  for (const mod of mods) {
    if (text(mod).toLowerCase() === "hyper") { ["Control", "Alt", "Shift", "Super"].forEach(flag => flags.add(flag)); continue; }
    const flag = modifiers[text(mod).toLowerCase()]; if (!flag) return;
    flags.add(flag);
  }
  return [...["Control", "Alt", "Shift", "Super"].filter(flag => flags.has(flag)), keys[code]].join("+");
}
const windows = new Map(prismCommandDefinitions.filter(command => command.id.startsWith("window:")).map(command => [command.id.slice(7).replaceAll("-", "").toLowerCase(), command.id]));
windows.set("firsttwothirds", "window:left-two-thirds"); windows.set("lasttwothirds", "window:right-two-thirds");
windows.set("restore", "window:restore-previous-layout");
windows.set("movenextdisplay", "window:next-display");
windows.set("movepreviousdisplay", "window:previous-display");
const builtins: Record<string, string> = {
  clipboardHistory: "clipboard:open-history", searchEmoji: "prism:emoji", fileSearch: "prism:files", searchFiles: "prism:files",
  searchSnippets: "prism:snippets", searchQuicklinks: "prism:links", lockScreen: "system:lock-screen",
  sleep: systemCommandIds.sleep, sleepDisplays: systemCommandIds.sleepDisplays,
  restart: systemCommandIds.restart, shutDown: systemCommandIds.shutdown, shutdown: systemCommandIds.shutdown,
  logOut: systemCommandIds.logOut, logout: systemCommandIds.logOut,
  openPreferences: "prism:preferences", showPreferences: "prism:preferences",
  aiChat: "prism:ai-chat",
};
// Resolve package and command together. An extension with a matching leaf name
// must never turn into a system action, and force/immediate variants stay unsupported.
const packageBuiltins: Record<string, Readonly<Record<string, string>>> = {
  system: Object.fromEntries(["lockScreen", "sleep", "sleepDisplays", "restart", "shutDown", "shutdown", "logOut", "logout"].map(name => [name, builtins[name]])),
  clipboardHistory: { clipboardHistory: "clipboard:open-history" },
  emoji: { searchEmoji: "prism:emoji" },
  fileSearch: { fileSearch: "prism:files", searchFiles: "prism:files" },
  snippets: { searchSnippets: "prism:snippets" },
  quicklinks: { searchQuicklinks: "prism:links" },
  raycastPreferences: { openPreferences: "prism:preferences", showPreferences: "prism:preferences" },
  "open-ai": { aiChat: "prism:ai-chat" },
};
packageBuiltins.systemActions = packageBuiltins.system;
export function resolveRaycastCommand(key: string, path: string, apps: NativeApplication[]): string | undefined {
  const appPath = path || (key.startsWith("c:r:applications::*::application::=::") ? key.split("::=::")[1] : "");
  if (appPath) { const app = apps.find(app => app.path.normalize("NFC") === appPath.normalize("NFC")); return app ? `native:${app.id}` : undefined; }
  if (key.startsWith("builtin_command_")) {
    const name = key.slice("builtin_command_".length);
    if (Object.hasOwn(builtins, name)) return builtins[name];
    const windowName = name.replace(/^windowManagement[_-]?/i, "").replace(/[-_]/g, "").toLowerCase();
    return windows.get(windowName);
  }
  const match = /^c:r:([^:]+)::(?:\*|-)::([^:]+)$/.exec(key);
  if (!match) return;
  const [, packageName, name] = match;
  if (packageName === "windowManagement" || packageName === "window-management") return windows.get(name.replace(/[-_]/g, "").toLowerCase());
  const commands = Object.hasOwn(packageBuiltins, packageName) ? packageBuiltins[packageName] : undefined;
  return commands && Object.hasOwn(commands, name) ? commands[name] : undefined;
}
export function buildRaycastPlan(data: unknown, context: ImportContext): ImportItem[] {
  const root = record(data);
  const systemCommands = systemCommandDefinitions(context.platform ?? "macos", context.capabilities);
  const classic = Object.keys(root).some(key => key.startsWith("builtin_package_"));
  const modern = ["snippets", "quicklinks", "settings"].some(key => Object.hasOwn(root, key));
  if (!Array.isArray(data) && !classic && !modern) throw new Error("Unsupported Raycast data.");
  const rows: ImportItem[] = [];
  const add = (item: Omit<ImportItem, "id">) => { if (rows.length >= 3000) throw new Error("Too many import items."); rows.push({ id: String(rows.length), ...item }); };
  const snippetSource = Array.isArray(data) ? data.filter(item => Object.hasOwn(record(item), "text")) : list(child(root[classic ? "builtin_package_snippets" : "snippets"], "snippets"));
  const linkSource = Array.isArray(data) ? data.filter(item => !Object.hasOwn(record(item), "text")) : list(child(root[classic ? "builtin_package_quicklinks" : "quicklinks"], "quicklinks"));
  if (snippetSource.length + linkSource.length > 3000) throw new Error("Too many import items.");
  for (const [category, source] of [["snippets", snippetSource], ["quicklinks", linkSource]] as const) {
    for (const raw of source) {
      const item = record(raw); const title = text(item.name) || text(item.title) || "Untitled";
      const original = category === "snippets" ? text(item.text) : text(item.url) || text(item.link);
      const value = category === "quicklinks" ? original.replace(/\{(?:Query|query|argument)\}/g, "{query}") : original;
      const keyword = text(item.keyword) || text(item.alias);
      let reason: string | undefined;
      if (!(text(item.name) || text(item.title)).trim() || !safeName(title) || byteLength(title) > 300 || !value.trim() || byteLength(value) > 128 * 1024 || value.includes("\0")) reason = "Invalid or oversized item";
      const tokens = value.match(/\{[^{}]+\}/g) ?? [];
      if (tokens.some(token => !(category === "snippets" ? ["{date}", "{time}", "{clipboard}"] : ["{query}"]).includes(token))) reason = "Unsupported placeholder";
      if (category === "quicklinks") {
        try { const url = new URL(value.replaceAll("{query}", "prism")); if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || value.split("?")[0].includes("{query}") || value.split("#")[1]?.includes("{query}")) reason = "Unsupported link"; }
        catch { reason = "Unsupported link"; }
      }
      // Prism expansion keywords are deliberately explicit; preserve content without inventing a new trigger.
      const validKeyword = /^[:;!/][a-zA-Z0-9_\-;!/:]{1,47}$/.test(keyword);
      const entry: LibraryEntry = { id: crypto.randomUUID(), kind: category === "snippets" ? "snippet" : "link", title, value, ...(category === "snippets" && validKeyword ? { keyword } : {}) };
      const duplicate = [...context.entries, ...rows.flatMap(row => row.entry && !row.reason && !row.conflict ? [row.entry] : [])].some(existing => existing.kind === entry.kind && (existing.value === value || existing.title === title || Boolean(entry.keyword && existing.keyword === entry.keyword)));
      add({ category, title, value, entry, reason, conflict: duplicate });
      if (category === "snippets" && keyword && !validKeyword) add({ category, title: `${title} · ${keyword}`, value: keyword, reason: "Expansion keyword needs a prefix (: ; ! /)" });
    }
  }
  const commands = [...(classic ? list(child(root.builtin_package_rootSearch, "rootSearch")) : list(child(root.settings, "commands")))];
  if (commands.length > 3000) throw new Error("Too many import items.");
  const global = child(child(root.builtin_package_raycastPreferences, "preferencesGeneral"), "raycastGlobalHotkey");
  if (global) commands.unshift({ key: "prism-launcher", hotkey: global });
  for (const raw of commands) {
    const item = record(raw), key = text(item.key) || text(item.id);
    const commandId = key === "prism-launcher" ? "launcher" : resolveRaycastCommand(key, text(item.path), context.apps);
    const title = commandId === "launcher" ? "Open or hide Prism" : prismCommandDefinitions.find(command => command.id === commandId)?.title || systemCommands.find(command => command.id === commandId)?.title || context.apps.find(app => `native:${app.id}` === commandId)?.name || text(item.name) || text(item.path).split("/").pop() || key;
    const hotkeyRaw = item.hotkey ?? item.macosHotkey;
    const alias = text(item.alias) || text(item.searchTerms);
    for (const category of ["hotkeys", "aliases"] as const) {
      if (category === "hotkeys" ? !hotkeyRaw : !alias) continue;
      const value = category === "hotkeys" ? raycastHotkey(hotkeyRaw) ?? "" : alias.trim();
      let reason = !commandId ? "No matching Prism command or installed app" : context.disabled.includes(commandId) ? "Command is disabled in Prism" : undefined;
      if (commandId?.startsWith("system:") && !systemCommands.some(command => command.id === commandId)) reason = "Command is unavailable on this platform";
      if (commandId?.startsWith("window:") && context.capabilities?.windowManagement === false) reason = "Command is unavailable on this platform";
      if (!value || (category === "aliases" && (!safeName(value) || value.length > 80))) reason = category === "hotkeys" ? "Unsupported shortcut" : "Unsupported alias";
      const existing = category === "hotkeys" ? context.hotkeys : context.aliases;
      const normalize = category === "hotkeys" ? canonicalHotkey : (value: string) => value.normalize("NFKC").trim().toLowerCase();
      const conflict = Boolean(commandId && (Object.hasOwn(existing, commandId) || Object.values(existing).some(used => normalize(used) === normalize(value)) || rows.some(row => row.category === category && !row.reason && !row.conflict && (row.commandId === commandId || normalize(row.value) === normalize(value)))));
      add({ category, title, value, commandId, before: commandId ? existing[commandId] : undefined, reason, conflict });
    }
  }
  for (const key of Object.keys(root)) {
    if (/windowManagement|extensions|aiChats|clipboardHistory|notes|mcp|scriptCommands|navigation|wrapped|emoji/i.test(key) && !/rootSearch/.test(key)) add({ category: "hotkeys", title: key, value: "", reason: "This category is not supported yet" });
  }
  return rows;
}
