import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

const native = vi.hoisted(() => ({
  invoke: vi.fn(), hide: vi.fn(), close: vi.fn(),
  listeners: new Map<string, (event: { payload: unknown }) => void>(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ hide: native.hide, close: native.close }),
}));
vi.mock("@tauri-apps/api/event", () => ({
  emit: vi.fn(async () => undefined),
  listen: vi.fn(async (name, callback) => {
    native.listeners.set(name, callback);
    return () => { native.listeners.delete(name); };
  }),
}));

let App: typeof import("./App").App;
let root: Root;
let container: HTMLDivElement;

beforeAll(async () => {
  Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
  App = (await import("./App")).App;
  await import("./emoji/EmojiPicker");
  await (await import("./emoji/catalog")).loadEmojiCatalog();
});

beforeEach(() => {
  Object.defineProperty(navigator,"language",{configurable:true,value:"en-US"});
  vi.useFakeTimers();
  window.history.replaceState({}, "", "/");
  localStorage.clear();
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: vi.fn(async () => undefined) } });
  native.hide.mockReset().mockResolvedValue(undefined);
  native.close.mockReset().mockResolvedValue(undefined);
  native.invoke.mockReset().mockImplementation(async (command: string, args?: unknown) => {
    switch (command) {
      case "get_global_shortcut": return {
        accelerator: "shift+control+Space", defaultAccelerator: "shift+control+Space",
        isDefault: true, registered: true, issue: null,
      };
      case "set_global_shortcut": return { accelerator: (args as { accelerator: string }).accelerator, defaultAccelerator: "shift+control+Space", isDefault: false, registered: true, issue: null };
      case "get_accessibility_permission_status": return { supported: true, granted: false, canRequest: true, message: "Permission required" };
      case "get_clipboard_history_enabled": return true;
      case "get_clipboard_history_settings": return {enabled:true,retentionDays:30,entryCount:1,pinnedCount:0,capacity:1000,persistenceError:null};
      case "prepare_window_appearance":
      case "reveal_palette":
      case "window_render_ready": return undefined;
      case "system_platform": return "macos";
      case "desktop_capabilities": return {windowManagement:true,paste:true,sleepDisplays:true,logOut:true,reason:null};
      case "load_system_icon": return null;
      case "clear_application_icon_cache": return undefined;
      case "get_command_shortcuts":
      case "search_applications":
      case "list_script_command_runs":
      case "list_script_commands": return [];
      case "library_search_files": return {items:[],total:0,limited:false};
      case "library_load": return { entries: [], roots: [], favorites: [] };
      case "ai_load_history": return [];
      case "ai_save_session": return (args as {session: unknown}).session;
      case "search_clipboard_history": return [{ id: 1, text: "A copied fixture", capturedAt: 1 }];
      case "get_clipboard_history_entry_text": return "A copied fixture";
      case "refresh_script_commands": return { commands: [], scannedDirectories: 0, skippedEntries: 0 };
      case "set_ai_workspace":
      case "set_shortcut_capture":
      case "set_window_blur":
      case "open_settings_window": return undefined;
      default: throw new Error(`Unexpected native call in interaction test: ${command}`);
    }
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => { root.unmount(); });
  container.remove();
  vi.useRealTimers();
});

async function settle() {
  await act(async () => { await vi.advanceTimersByTimeAsync(100); });
}
async function mount(settings = false) {
  if (settings) window.history.replaceState({}, "", "/?window=settings");
  await act(async () => { root.render(<App />); });
  await settle();
}
function input(): HTMLInputElement {
  const element = container.querySelector<HTMLInputElement>('[role="combobox"]');
  if (!element) throw new Error("Search input is missing");
  return element;
}
function button(text: string): HTMLButtonElement {
  const element = [...container.querySelectorAll("button")].find((button) =>
    button.textContent?.trim() === text || button.getAttribute("aria-label") === text);
  if (!element) throw new Error(`Missing button: ${text}`);
  return element;
}
async function click(element: HTMLElement) {
  await act(async () => { element.focus(); element.click(); });
  await settle();
}
async function type(value: string, target = input()) {
  await act(async () => {
    target.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(target, value);
    target.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await settle();
}
async function key(key: string, init: KeyboardEventInit = {}, target: EventTarget = document.activeElement!) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  await act(async () => { target.dispatchEvent(event); });
  await settle();
  return event;
}
function selectedId() { return input().getAttribute("aria-activedescendant"); }

describe("mounted palette keyboard flows with mocked native IPC", () => {
  it("cycles repeated background window hotkeys without requesting a palette reveal", async () => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "manage_window"
      ? Promise.resolve({ applied: true, supported: true, message: "Window moved" }) : original(command, args));
    await mount();
    for (let step = 0; step < 4; step++) {
      await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "window:right-half", background: true } }); });
      await settle();
    }
    expect(native.invoke.mock.calls.filter(([command]) => command === "manage_window")).toEqual(Array(4).fill(["manage_window", { action: "right-half" }]));
    expect(native.invoke).not.toHaveBeenCalledWith("reveal_palette");
    expect(native.hide).toHaveBeenCalledTimes(4);
  });

  it.each(["rejection", "unapplied"])("shows a background window failure only after native %s", async failure => {
    const original = native.invoke.getMockImplementation()!;
    let finish!: () => void;
    native.invoke.mockImplementation((command, args) => command === "manage_window"
      ? new Promise((resolve, reject) => { finish = () => failure === "rejection"
        ? reject({ code: "accessibilityPermissionRequired", message: "Allow Accessibility to move windows." })
        : resolve({ applied: false, message: "Allow Accessibility to move windows." }); }) : original(command, args));
    await mount();
    await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "window:left-half", background: true } }); });
    expect(native.invoke).not.toHaveBeenCalledWith("reveal_palette");
    await act(async () => { finish(); });
    await settle();
    expect(native.invoke).toHaveBeenCalledWith("reveal_palette");
    expect(container.textContent).toContain("Allow Accessibility to move windows.");
    expect(native.hide).not.toHaveBeenCalled();
  });

  it("opens Settings from a background hotkey without opening the main palette", async () => {
    await mount();
    await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "prism:preferences", background: true } }); });
    await settle();
    expect(native.invoke).toHaveBeenCalledWith("open_settings_window");
    expect(native.invoke).not.toHaveBeenCalledWith("reveal_palette");
  });

  it.each([true, false])("handles background application availability (%s) without a success flash", async available => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => {
      if (command === "get_application") return Promise.resolve(available ? { id: "fixture", name: "Fixture", path: "/Applications/Fixture.app", platform: "macos", rankingBoost: 0 } : null);
      if (command === "launch_application") return Promise.resolve({ launched: true });
      return original(command, args);
    });
    await mount();
    await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "native:fixture", background: true } }); });
    await settle();
    if (available) {
      expect(native.invoke).toHaveBeenCalledWith("launch_application", { applicationId: "fixture", target: "/Applications/Fixture.app" });
      expect(native.invoke).not.toHaveBeenCalledWith("reveal_palette");
    } else {
      expect(native.invoke.mock.calls.some(([command]) => command === "launch_application")).toBe(false);
      expect(native.invoke).toHaveBeenCalledWith("reveal_palette");
      expect(container.textContent).toContain("The application is no longer available in the local index");
    }
  });

  it("does not execute or reveal a disabled background window command", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ disabledCommandIds: ["window:right-half"] }));
    await mount();
    await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "window:right-half", background: true } }); });
    await settle();
    expect(native.invoke.mock.calls.some(([command]) => command === "manage_window")).toBe(false);
    expect(native.invoke).not.toHaveBeenCalledWith("reveal_palette");
  });

  it("keeps cancelled background system confirmation silent", async () => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "run_system_action"
      ? Promise.resolve({ applied: false, message: "" }) : original(command, args));
    await mount();
    await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "system:restart", background: true } }); });
    await settle();
    expect(native.invoke).toHaveBeenCalledWith("run_system_action", { commandId: "system:restart", locale: "en" });
    expect(native.invoke).not.toHaveBeenCalledWith("reveal_palette");
    expect(native.hide).not.toHaveBeenCalled();
  });

  it("previews system actions in the browser without sending native IPC", async () => {
    const platform = Object.getOwnPropertyDescriptor(navigator, "platform");
    Object.defineProperty(navigator, "platform", { configurable: true, value: "MacIntel" });
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: undefined });
    try {
      await mount();
      await type("restart");
      expect(selectedId()).toBe("result-system:restart");
      await key("Enter");
      expect(container.textContent).toContain("System commands are available in the Prism desktop app");
      expect(native.invoke.mock.calls.some(([command]) => command === "run_system_action")).toBe(false);
    } finally {
      Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
      if (platform) Object.defineProperty(navigator, "platform", platform);
      else Reflect.deleteProperty(navigator, "platform");
    }
  });

  it("routes a searched Restart to native confirmation and keeps the palette on cancellation", async () => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "run_system_action"
      ? Promise.resolve({ commandId: "system:restart", platform: "macos", applied: false, message: "" }) : original(command, args));
    await mount();
    await type("restart");
    expect(selectedId()).toBe("result-system:restart");
    await key("Enter");
    expect(native.invoke).toHaveBeenCalledWith("run_system_action", { commandId: "system:restart", locale: "en" });
    expect(native.hide).not.toHaveBeenCalled();
    expect(input().value).toBe("restart");
  });

  it("routes a power hotkey through the same native command and dismisses only after acceptance", async () => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "run_system_action"
      ? Promise.resolve({ commandId: "system:sleep", platform: "macos", applied: true, message: "" }) : original(command, args));
    await mount();
    await act(async () => { native.listeners.get("prism:command-hotkey")!({ payload: { commandId: "system:sleep" } }); });
    await settle();
    expect(native.invoke).toHaveBeenCalledWith("run_system_action", { commandId: "system:sleep", locale: "en" });
    expect(native.hide).toHaveBeenCalledOnce();
  });

  it("finds an imported power alias and reports native refusal without dismissing", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ commandAliases: { "system:shutdown": "poweroff" } }));
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "run_system_action"
      ? Promise.reject({ code: "actionFailed", message: "macOS declined the session request." }) : original(command, args));
    await mount();
    await type("poweroff");
    expect(selectedId()).toBe("result-system:shutdown");
    await key("Enter");
    expect(native.hide).not.toHaveBeenCalled();
    expect(container.textContent).toContain("macOS declined the session request.");
  });

  it("queries cached files promptly and keeps Enter on Clipboard History when files arrive", async () => {
    const original = native.invoke.getMockImplementation()!;
    let releaseFiles!: (value: unknown) => void;
    native.invoke.mockImplementation((command, args) => command === "library_search_files"
      ? new Promise(resolve => { releaseFiles = resolve; }) : original(command, args));
    await mount();
    await type("cl");
    await type("cli");
    await type("clip");
    expect(selectedId()).toBe("result-clipboard:open-history");
    const lookups = native.invoke.mock.calls.filter(([command]) => command === "library_search_files");
    expect(lookups.length).toBeGreaterThan(0);
    expect(lookups.at(-1)?.[1]).toMatchObject({ query: "clip" });
    await act(async () => { releaseFiles({ items: [{ id: "clip-file", name: "clip", path: "/fixture/clip", isDirectory: false }], total: 1, limited: false }); });
    const rows = [...container.querySelectorAll('#command-results [role="option"]')];
    expect(rows[0]?.id).toBe("result-clipboard:open-history");
    expect(rows.some((row) => row.id === "result-file:clip-file")).toBe(true);
    expect(selectedId()).toBe("result-clipboard:open-history");
    await key("Enter");
    expect(input().getAttribute("aria-label")).toBe("Search clipboard history");
    expect(native.invoke.mock.calls.some(([command]) => command === "library_file_action")).toBe(false);
  });

  it("refreshes the current file query when a background index publishes", async () => {
    const original = native.invoke.getMockImplementation()!;
    let available = false;
    native.invoke.mockImplementation((command, args) => command === "library_search_files"
      ? Promise.resolve({ items: available ? [{ id: "fresh", name: "report.txt", path: "/fixture/report.txt", isDirectory: false }] : [], total: available ? 1 : 0, limited: false })
      : original(command, args));
    await mount();
    await type("report");
    expect(container.querySelector('[id="result-file:fresh"]')).toBeNull();
    available = true;
    await act(async () => { native.listeners.get("prism:file-index-changed")?.({ payload: null }); });
    await settle();
    expect(input().value).toBe("report");
    expect(container.querySelector('[id="result-file:fresh"]')).not.toBeNull();
  });

  it("pins a command through its action menu and restores its ordering after remount", async () => {
    const original = native.invoke.getMockImplementation()!;
    let favorites: {id: string; title: string}[] = [];
    native.invoke.mockImplementation(async (command, args) => {
      if (command === "library_load") return {entries: [], roots: [], favorites};
      if (command === "library_set_favorite") { favorites = [args.favorite]; return; }
      return original(command, args);
    });
    await mount();
    await type("cycle");
    await key("k", {ctrlKey: true});
    const field = container.querySelector<HTMLInputElement>('[aria-label="Search actions"]')!;
    await type("즐겨찾기 추가", field);
    await key("Enter", {}, field);
    expect(favorites[0].id).toBe("prism:cycle-theme");
    await act(async () => { root.unmount(); });
    root = createRoot(container);
    await mount();
    expect(selectedId()).toBe("result-prism:cycle-theme");
    expect(container.querySelector('[aria-label="Favorites"]')).not.toBeNull();
  });

  it("copies without dismissing, then deletes only the chosen clipboard entry", async () => {
    const original = native.invoke.getMockImplementation()!;
    let entries = [{id: 1, text: "A copied fixture", capturedAt: 1}, {id: 2, text: "Second fixture", capturedAt: 2}];
    native.invoke.mockImplementation(async (command, args) => {
      if (command === "search_clipboard_history") return entries;
      if (command === "get_clipboard_history_entry_text") return entries.find(entry => entry.id === args.id)?.text;
      if (command === "copy_clipboard_history_entry") return;
      if (command === "delete_clipboard_history_entry") { entries = entries.filter(e => e.id !== args.id); return; }
      return original(command, args);
    });
    await mount();
    await type("clipboard");
    await key("Enter");
    await key("Enter");
    expect(native.invoke).toHaveBeenCalledWith("copy_clipboard_history_entry", {id: 1});
    expect(native.hide).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(input());
    await key("k", {ctrlKey: true});
    const field = container.querySelector<HTMLInputElement>('[aria-label="Search actions"]')!;
    await type("기록에서 삭제", field);
    await key("Enter", {}, field);
    expect(entries.map(e => e.id)).toEqual([2]);
    expect(container.textContent).not.toContain("A copied fixture");
    expect(container.textContent).toContain("Second fixture");
    expect(native.hide).not.toHaveBeenCalled();
  });

  it("keeps a matching application's DOM row mounted while the next query is loading", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ showApplicationIcons: false }));
    const original = native.invoke.getMockImplementation()!;
    const application = { id: "paper", name: "Paper Editor", path: "/fixture/Paper.app", platform: "macos", rankingBoost: 0 };
    let release!: (value: unknown) => void;
    native.invoke.mockImplementation((command, args) => {
      if (command !== "search_applications") return original(command, args);
      return args.query === "pap" ? new Promise((resolve) => { release = resolve; }) : Promise.resolve([application]);
    });
    await mount();
    await type("pa");
    const row = container.querySelector('[id="result-native:paper"]')!;
    expect(row).not.toBeNull();
    const removed: Node[] = [];
    const observer = new MutationObserver((records) => {
      for (const record of records) removed.push(...record.removedNodes);
    });
    observer.observe(container, { childList: true, subtree: true });
    try {
      await type("pap");
      expect(container.querySelector('[id="result-native:paper"]')).toBe(row);
      expect(container.querySelector('[aria-label="Searching"]')).toBeNull();
      expect(selectedId()).toBe("result-native:paper");
      await act(async () => { release([{ ...application, rankingBoost: 10 }]); });
      expect(container.querySelector('[id="result-native:paper"]')).toBe(row);
      expect(removed.some((node) => node === row || node.contains(row))).toBe(false);
    } finally {
      observer.disconnect();
    }
  });

  it("removes a retained application when its current search completes without a match", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ showApplicationIcons: false }));
    const original = native.invoke.getMockImplementation()!;
    let release!: (value: unknown) => void;
    native.invoke.mockImplementation((command, args) => command !== "search_applications" ? original(command, args)
      : args.query === "pap" ? new Promise((resolve) => { release = resolve; })
      : Promise.resolve([{ id: "paper", name: "Paper Editor", path: "/fixture/Paper.app", platform: "macos", rankingBoost: 0 }]));
    await mount();
    await type("pap");
    expect(container.querySelector('[id="result-native:paper"]')).not.toBeNull();
    await act(async () => { release([]); });
    expect(container.querySelector('[id="result-native:paper"]')).toBeNull();
    await key("Enter");
    expect(native.invoke).not.toHaveBeenCalledWith("launch_application", expect.anything());
  });

  it("keeps fast commands usable before a slow source times out, then retries without clearing", async () => {
    await mount();
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, ...args) => command === "search_applications"
      ? new Promise(() => undefined) : original(command, ...args));
    await type("cycle");
    expect(selectedId()).toBe("result-prism:cycle-theme");
    expect(container.textContent).not.toContain("took too long");
    await act(async () => { await vi.advanceTimersByTimeAsync(500); });
    expect(container.textContent).toContain("took too long");
    native.invoke.mockImplementation(original);
    await click(button("Retry"));
    expect(input().value).toBe("cycle");
    expect(container.textContent).not.toContain("took too long");
  });

  it("does not paint a late application's result into a newer search", async () => {
    await mount();
    const original = native.invoke.getMockImplementation()!;
    let release!: (value: unknown) => void;
    native.invoke.mockImplementation((command, args) => command === "search_applications" && args.query === "late"
      ? new Promise((resolve) => { release = resolve; }) : original(command, args));
    await type("late");
    await type("cycle");
    await act(async () => { release([{ id: "late", name: "Late App", path: "/fixture/Late.app", platform: "macos", rankingBoost: 0 }]); });
    expect(selectedId()).toBe("result-prism:cycle-theme");
    expect(container.textContent).not.toContain("Late App");
  });

  it("shows an expression result, labels Copy correctly and drops it for the next query", async () => {
    await mount();
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, ...args) => command === "calculate_arithmetic" ? Promise.resolve("8") : original(command, ...args));
    await type("4+4");
    expect(selectedId()).toBe("result-calculator:result");
    expect(container.querySelector(".result-open")?.textContent).toContain("Copy result");
    await key("Enter");
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("8");
    expect(native.hide).not.toHaveBeenCalled();
    await type("cycle");
    expect(container.querySelector('[id="result-calculator:result"]')).toBeNull();
  });

  it("filters actions independently, preserves their original target on refresh and copies the path", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ showApplicationIcons: false }));
    const original = native.invoke.getMockImplementation()!;
    let application = { id: "paper", name: "Paper Editor", path: "/fixture/Paper.app", platform: "macos", rankingBoost: 0 };
    native.invoke.mockImplementation((command, ...args) => command === "search_applications" ? Promise.resolve([application]) : original(command, ...args));
    await mount();
    await type("paper");
    const applicationRow = container.querySelector('[id="result-native:paper"]')!;
    expect(applicationRow.textContent).toBe("Paper Editor");
    expect(applicationRow.querySelector("small")).toBeNull();
    expect(container.querySelector(".statusbar-primary")?.textContent).toContain("Open");
    await key("k", { ctrlKey: true });
    const field = container.querySelector<HTMLInputElement>('[aria-label="Search actions"]')!;
    expect(document.activeElement).toBe(field);
    await type("copy", field);
    expect(container.querySelectorAll('#available-actions [role="option"]')).toHaveLength(1);
    expect(input().value).toBe("paper");
    application = { ...application, id: "replacement", name: "Paper Backup", path: "/fixture/Backup.app" };
    await act(async () => { native.listeners.get("prism:application-index-updated")!({ payload: { applicationCount: 1 } }); });
    await key("Enter", {}, field);
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("/fixture/Paper.app");
    expect(document.activeElement).toBe(input());
  });

  it("does not run a hidden action when the action filter has no results", async () => {
    await mount();
    await type("cycle");
    await key("k", { ctrlKey: true });
    const field = container.querySelector<HTMLInputElement>('[aria-label="Search actions"]')!;
    await type("no-such-action", field);
    const previous = document.documentElement.dataset.theme;
    await key("Enter", {}, field);
    expect(document.documentElement.dataset.theme).toBe(previous);
    expect(container.textContent).toContain("No matching actions");
    await key("Escape", {}, field);
    expect(input().value).toBe("cycle");
  });

  it("returns focus to search after a result is clicked without an action panel", async () => {
    await mount();
    await type("cycle");
    const row = container.querySelector<HTMLElement>('[id="result-prism:cycle-theme"]')!;
    await click(row);
    expect(document.activeElement).toBe(input());
  });

  it("focuses search, clears a root query on Escape, then hides on a separate Escape", async () => {
    await mount();
    expect(document.activeElement).toBe(input());
    await type("cycle");
    await key("Escape");
    expect(input().value).toBe("");
    expect(native.hide).not.toHaveBeenCalled();
    await key("Escape", { repeat: true });
    expect(native.hide).not.toHaveBeenCalled();
    await key("Escape");
    expect(native.hide).toHaveBeenCalledOnce();
  });

  it.each([{ isComposing: true }, { keyCode: 229 }])("does not execute a composition Enter (%j)", async (flags) => {
    await mount();
    await type("cycle");
    const previous = document.documentElement.dataset.theme;
    const event = await key("Enter", flags);
    expect(event.defaultPrevented).toBe(false);
    expect(document.documentElement.dataset.theme).toBe(previous);
    await key("Enter");
    expect(document.documentElement.dataset.theme).not.toBe(previous);
  });

  it("honors composition events when the keyboard flag is absent, without eating the next Enter", async () => {
    await mount();
    await type("cycle");
    const previous = document.documentElement.dataset.theme;
    input().dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    await key("Enter");
    await key("Escape");
    expect(input().value).toBe("cycle");
    expect(document.documentElement.dataset.theme).toBe(previous);
    input().dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
    await key("Enter", { keyCode: 229 });
    expect(document.documentElement.dataset.theme).toBe(previous);
    await key("Enter");
    expect(document.documentElement.dataset.theme).not.toBe(previous);
    await key("Enter", { repeat: true });
    expect(document.documentElement.dataset.theme).not.toBe(previous);
  });

  it("clamps list selection instead of wrapping", async () => {
    await mount();
    const first = selectedId();
    await key("ArrowUp");
    expect(selectedId()).toBe(first);
    const resultCount = container.querySelectorAll('#command-results [role="option"]').length;
    for (let i = 0; i < resultCount; i++) await key("ArrowDown");
    const last = selectedId();
    await key("ArrowDown");
    expect(selectedId()).toBe(last);
  });

  it("clears a scoped query before returning, restoring the parent's selection and scroll", async () => {
    await mount();
    const resultCount = container.querySelectorAll('#command-results [role="option"]').length;
    for (let i = 0; i < resultCount && selectedId() !== "result-clipboard:open-history"; i++) {
      await key("ArrowDown");
    }
    expect(selectedId()).toBe("result-clipboard:open-history");
    const parentId = selectedId();
    const scroll = container.querySelector<HTMLElement>("#command-results")!;
    scroll.scrollTop = 96;
    await key("Enter");
    expect(input().getAttribute("aria-label")).toBe("Search clipboard history");
    await type("copied");
    await key("Escape");
    expect(input().value).toBe("");
    expect(input().getAttribute("aria-label")).toBe("Search clipboard history");
    await key("Escape");
    expect(input().getAttribute("aria-label")).toBe("Search apps and commands");
    expect(selectedId()).toBe(parentId);
    expect(scroll.scrollTop).toBe(96);
    expect(document.activeElement).toBe(input());
    expect(native.hide).not.toHaveBeenCalled();
  });

  it("uses the same parent restoration for the back button", async () => {
    await mount();
    await type("clipboard");
    const parentId = selectedId();
    await key("Enter");
    await type("entry");
    await click(button("Back to all commands"));
    expect(input().value).toBe("clipboard");
    expect(selectedId()).toBe(parentId);
    expect(document.activeElement).toBe(input());
  });

  it("keeps action-panel focus contained and returns to the invoking search on close", async () => {
    await mount();
    await type("cycle");
    const selected = selectedId();
    await key("k", { ctrlKey: true });
    const panel = container.querySelector('[role="dialog"]')!;
    expect(panel.contains(document.activeElement)).toBe(true);
    await key("Tab");
    expect(document.activeElement).toBe(button("Close actions"));
    expect((await key("Enter")).defaultPrevented).toBe(false);
    await click(button("Close actions"));
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(input().value).toBe("cycle");
    expect(selectedId()).toBe(selected);
    expect(document.activeElement).toBe(input());
  });

  it("closes actions before clearing root text and protects action execution during IME", async () => {
    await mount();
    await type("cycle");
    await key("k", { ctrlKey: true });
    const previous = document.documentElement.dataset.theme;
    await key("Enter", { isComposing: true });
    expect(document.documentElement.dataset.theme).toBe(previous);
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    await key("Escape");
    expect(input().value).toBe("cycle");
    expect(document.activeElement).toBe(input());
  });

  it("preserves the search when hiding fails", async () => {
    await mount();
    await type("cycle");
    native.hide.mockRejectedValueOnce(new Error("Window unavailable"));
    await key("w", { ctrlKey: true });
    expect(input().value).toBe("cycle");
    expect(container.querySelector(".toast")?.textContent).toContain("Window unavailable");
  });

  it("does not erase a visible recovery window's query on focus loss", async () => {
    await mount();
    await act(async () => {
      native.listeners.get("prism:global-shortcut-changed")!({ payload: {
        accelerator: "", defaultAccelerator: "shift+control+Space", registered: false, isDefault: false, issue: null,
      } });
    });
    await type("cycle");
    await act(async () => { window.dispatchEvent(new Event("blur")); window.dispatchEvent(new Event("focus")); });
    expect(input().value).toBe("cycle");
  });

  it("keeps root commands out of settings inputs and guards a script-folder composition Enter", async () => {
    await mount(true);
    await click(button("Scripts"));
    const field = container.querySelector<HTMLInputElement>('[aria-label="Local script directory"]')!;
    await type("/tmp/한글", field);
    await key("Enter", { isComposing: true }, field);
    expect(container.querySelector('[aria-label="Configured script directories"]')).toBeNull();
    await key("Enter", {}, field);
    expect(container.querySelector('[aria-label="Configured script directories"]')?.textContent).toContain("/tmp/한글");
    expect(native.hide).not.toHaveBeenCalled();
    await key("Escape", {}, field);
    expect(native.close).toHaveBeenCalledOnce();
  });

  it("cancels a settings confirmation before closing, keeping keyboard focus on its trigger", async () => {
    await mount(true);
    await click(button("Clipboard"));
    await click(button("Clear history"));
    expect(document.activeElement).toBe(button("Cancel"));
    await key("Escape");
    expect(native.close).not.toHaveBeenCalled();
    expect(native.invoke).not.toHaveBeenCalledWith("clear_clipboard_history");
    expect(document.activeElement).toBe(button("Clear history"));
    await key("Escape");
    expect(native.close).toHaveBeenCalledOnce();
  });

  it("cancels a shortcut recorder before handling Settings Escape", async () => {
    await mount(true);
    await click(button("Launcher"));
    const recorder = container.querySelector<HTMLButtonElement>(".shortcut-recorder")!;
    await click(recorder);
    expect(recorder.getAttribute("aria-pressed")).toBe("true");
    await key("Escape");
    expect(recorder.getAttribute("aria-pressed")).toBe("false");
    expect(native.close).not.toHaveBeenCalled();
    await key("Escape");
    expect(native.close).toHaveBeenCalledOnce();
  });

  it("records a launcher shortcut after a click that does not focus the button", async () => {
    await mount(true);
    await click(button("Launcher"));
    const recorder = container.querySelector<HTMLButtonElement>(".shortcut-recorder")!;
    // WebKit pointer clicks can leave focus on the previously active control.
    await act(async () => { recorder.click(); });
    expect(recorder.getAttribute("aria-pressed")).toBe("true");
    await key("Shift", { code: "ShiftLeft", shiftKey: true });
    expect(recorder.getAttribute("aria-pressed")).toBe("true");
    await key("p", { code: "KeyP", metaKey: true, shiftKey: true });
    expect(recorder.getAttribute("aria-pressed")).toBe("false");
    expect(recorder.textContent).toContain("P");
    expect(native.invoke).toHaveBeenCalledWith("set_global_shortcut", { accelerator: "Super+Shift+KeyP" });
    expect([...container.querySelectorAll("button")].some(button => button.textContent === "Save")).toBe(false);
    expect(document.activeElement).toBe(recorder);
    expect(native.close).not.toHaveBeenCalled();
  });

  it.each(["Commands", "Window Management", "Applications"])(
    "records a %s hotkey after clicking from an alias input without automatic focus",
    async (section) => {
      localStorage.setItem("prism:preferences", JSON.stringify({ showApplicationIcons: false }));
      const original = native.invoke.getMockImplementation()!;
      native.invoke.mockImplementation((command, args) => {
        if (command === "search_applications") return Promise.resolve([
          { id: "paper", name: "Paper Editor", path: "/fixture/Paper.app", platform: "macos", rankingBoost: 0 },
        ]);
        if (command === "set_command_shortcut") return Promise.resolve({
          commandId: args.commandId, accelerator: args.shortcut, registered: true, issue: null,
        });
        return original(command, args);
      });
      await mount(true);
      await click(button(section));
      await settle();
      const recorder = container.querySelector<HTMLButtonElement>(".command-hotkey:not(:disabled)")!;
      const row = recorder.closest(".settings-command-row")!;
      const alias = row.querySelector<HTMLInputElement>(".command-alias-input")!;
      alias.focus();
      await act(async () => { recorder.click(); });
      await key("p", { code: "KeyP", metaKey: true, shiftKey: true });
      expect(native.invoke).toHaveBeenCalledWith("set_command_shortcut", {
        commandId: expect.any(String), shortcut: "Super+Shift+KeyP",
      });
      expect(recorder.getAttribute("aria-pressed")).toBe("false");
      expect(recorder.textContent).toContain("P");
      expect(alias.value).toBe("");
      expect(native.close).not.toHaveBeenCalled();
    },
  );

  it.each(["status notification", "recorder blur"])("keeps a failed Control double-tap registration visible after %s and allows retry", async (notification) => {
    const { defaultSettings } = await import("./dictation/api");
    const original = native.invoke.getMockImplementation()!;
    const message = "Modifier double-tap shortcuts require Accessibility access.";
    let denied = true;
    native.invoke.mockImplementation(async (command, args) => {
      if (command === "dictation_get_settings") return defaultSettings;
      if (command === "dictation_action") return { phase: "idle", message: "", microphone: "granted", accessibility: !denied, hasTranscript: false };
      if (command === "set_command_shortcut") {
        if (denied) throw { code: "registrationConflict", message };
        return { commandId: args.commandId, accelerator: args.shortcut, registered: true, issue: null };
      }
      return original(command, args);
    });
    await mount(true); await click(button("Dictation"));
    const recorder = container.querySelector<HTMLButtonElement>('[aria-label="Global shortcut for Dictation"]')!;
    async function recordControlTwice() {
      await click(recorder);
      await key("Control", { code: "ControlLeft", ctrlKey: true }, recorder);
      await act(async () => { recorder.dispatchEvent(new KeyboardEvent("keyup", { key: "Control", code: "ControlLeft", bubbles: true })); });
      await key("Control", { code: "ControlLeft", ctrlKey: true }, recorder);
    }
    await recordControlTwice();
    expect(native.invoke).toHaveBeenCalledWith("set_command_shortcut", { commandId: "prism:dictation", shortcut: "DoubleControl" });
    expect(container.textContent).toContain(message);
    await act(async () => {
      if (notification === "status notification") native.listeners.get("prism:command-shortcuts-changed")!({ payload: [] });
      else recorder.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
    });
    await act(async () => { await vi.advanceTimersByTimeAsync(2500); });
    expect(container.textContent).toContain(message);
    expect(recorder.getAttribute("aria-pressed")).toBe("false");
    denied = false;
    await recordControlTwice();
    expect(container.textContent).not.toContain(message);
    expect(recorder.textContent).toContain("⌃");
    expect(native.invoke.mock.calls.some(([command]) => command === "dictation_toggle")).toBe(false);
  });

  it("uses the same artwork for every window layout in Settings and palette search", async () => {
    const { prismCommandDefinitions } = await import("./providers/prism");
    const layouts = prismCommandDefinitions.filter((command) => command.id.startsWith("window:"));
    await mount(true);
    await click(button("Window Management"));
    const artwork = new Map(layouts.map((command) => {
      const row = button(`Global shortcut for ${command.title}`).closest(".settings-command-row")!;
      const icon = row.querySelector(".command-glyph .window-layout-icon");
      expect(icon, command.title).not.toBeNull();
      return [command.id, icon!.outerHTML];
    }));
    window.history.replaceState({}, "", "/");
    await act(async () => { root.render(<App key="palette" />); });
    await settle();
    for (const command of layouts) {
      await type(command.title);
      const result = document.getElementById(`result-${command.id}`)!;
      expect(result.querySelector(".window-layout-icon")?.outerHTML, command.title).toBe(artwork.get(command.id));
      expect(result.querySelector(".command-glyph svg")).toBeNull();
    }
  });

  it("uses the launcher Prism identity for the Settings search result", async () => {
    await mount();
    const artwork = container.querySelector(".search-zone .prism-logo")!;
    expect(artwork).not.toBeNull();
    const paths = [...artwork.querySelectorAll("path")].map(path => path.getAttribute("d"));
    window.history.replaceState({}, "", "/");
    await act(async () => { root.render(<App key="palette" />); });
    await settle();
    await type("settings");
    const result = document.getElementById("result-prism:preferences")!;
    const resultArtwork = result.querySelector(".prism-logo")!;
    expect(resultArtwork).not.toBeNull();
    expect([...resultArtwork.querySelectorAll("path")].map(path => path.getAttribute("d"))).toEqual(paths);
    // Each mounted logo must resolve its own SVG paint servers.
    for (const path of resultArtwork.querySelectorAll('[fill^="url("]')) {
      const id = path.getAttribute("fill")!.slice(5, -1);
      expect([...resultArtwork.querySelectorAll("linearGradient")].some(gradient => gradient.id === id)).toBe(true);
    }
  });

  it("uses the original system artwork in both views even when application icons are disabled", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ showApplicationIcons: false }));
    const original = native.invoke.getMockImplementation()!;
    const iconUrl = "data:image/png;base64,c3lzdGVtLWljb24=";
    native.invoke.mockImplementation((command, args) => command === "load_system_icon"
      ? Promise.resolve(iconUrl) : original(command, args));
    const { clearNativeApplicationIconCache } = await import("./providers/native");
    await clearNativeApplicationIconCache();
    await mount(true);
    await click(button("Commands"));
    const row = button("Global shortcut for Notifications").closest(".settings-command-row")!;
    expect(row.querySelector(".command-glyph img")?.getAttribute("src")).toBe(iconUrl);
    window.history.replaceState({}, "", "/");
    await act(async () => { root.render(<App key="palette" />); });
    await settle();
    await type("notifications");
    const result = document.getElementById("result-system:settings:notifications")!;
    expect(result.querySelector(".command-glyph img")?.getAttribute("src")).toBe(iconUrl);
    expect(result.querySelector(".command-glyph svg")).toBeNull();
    expect(native.invoke).toHaveBeenCalledWith("load_system_icon", { commandId: "system:settings:notifications" });
  });

  it("does not substitute a drawn icon when the system artwork is loading or fails", async () => {
    const original = native.invoke.getMockImplementation()!;
    let reject!: (error: Error) => void;
    native.invoke.mockImplementation((command, args) => command === "load_system_icon" && args.commandId === "system:settings:notifications"
      ? new Promise((_, fail) => { reject = fail; }) : original(command, args));
    const { clearNativeApplicationIconCache } = await import("./providers/native");
    await clearNativeApplicationIconCache();
    await mount();
    await type("notifications");
    const result = document.getElementById("result-system:settings:notifications")!;
    expect(result.querySelector(".command-glyph svg")).toBeNull();
    expect(result.querySelector(".command-glyph img")).toBeNull();
    await act(async () => { reject(new Error("Native loader unavailable")); });
    expect(result.querySelector(".command-glyph svg")).toBeNull();
    expect(result.querySelector(".command-glyph img")).toBeNull();
  });

  it("shows a delayed exchange rate with its date and copies the displayed amount", async () => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "get_currency_rates"
      ? new Promise((resolve) => setTimeout(() => resolve({ date: "2026-09-04", fetchedAt: 1_788_652_800, rates: { EUR: 1, USD: 1.25, KRW: 1600 }, stale: true }), 800))
      : original(command, args));
    await mount();
    await type("100달러");
    await act(async () => { await vi.advanceTimersByTimeAsync(800); });
    expect(selectedId()).toBe("result-currency:USD:KRW");
    const result = document.getElementById("result-currency:USD:KRW")!;
    expect(result.getAttribute("aria-label")).toContain("100 USD = 128,000 KRW");
    expect(result.querySelector(".answer-input")?.textContent).toBe("100USD");
    expect(result.querySelector(".answer-value")?.textContent).toBe("128,000KRW");
    expect(result.textContent).toContain("Cached · refresh unavailable · 2026-09-04");
    await key("Enter");
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("128000");
    expect(native.hide).not.toHaveBeenCalled();
    await type("cycle");
    expect(document.getElementById("result-currency:USD:KRW")).toBeNull();
  });

  it("shows the expression and full calculator result in an instant answer", async () => {
    const original = native.invoke.getMockImplementation()!;
    const value = "123456789012345678.123456";
    native.invoke.mockImplementation((command, args) => command === "calculate_arithmetic"
      ? Promise.resolve(value) : original(command, args));
    await mount();
    await type("123456789012345678+0.123456");
    const answer = document.getElementById("result-calculator:result")!;
    expect(answer.classList.contains("instant-answer")).toBe(true);
    expect(answer.querySelector(".answer-input")?.textContent).toBe("123,456,789,012,345,678+0.123456");
    expect(answer.querySelector(".answer-value-long")?.textContent).toBe("123,456,789,012,345,678.123456");
    await key("k", { ctrlKey: true });
    await key("Enter");
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(value);
    await key("Escape");
    expect(container.querySelector(".instant-answer")).toBeNull();
  });

  it("keeps each overview result selectable and copies its own amount", async () => {
    const original = native.invoke.getMockImplementation()!;
    native.invoke.mockImplementation((command, args) => command === "get_currency_rates"
      ? Promise.resolve({ date: "2026-09-04", fetchedAt: 1_788_652_800, rates: { EUR: 1, USD: 1.25, KRW: 1600, JPY: 200, CNY: 8 }, stale: false })
      : original(command, args));
    await mount();
    await type("환율");
    expect(container.querySelectorAll(".answer-overview .instant-answer")).toHaveLength(4);
    expect(selectedId()).toBe("result-currency:USD:KRW");
    await key("ArrowDown");
    expect(selectedId()).toBe("result-currency:EUR:KRW");
    await key("Enter");
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith("1600");
    await click(document.getElementById("result-currency:JPY:KRW")!);
    expect(navigator.clipboard.writeText).toHaveBeenLastCalledWith("800");
    expect(document.activeElement).toBe(input());
    expect(input().value).toBe("환율");
    expect(native.hide).not.toHaveBeenCalled();
  });

  it("shows unit conversion as a large grouped answer and copies a plain number", async () => {
    await mount();
    await type("1 GB to B");
    expect(selectedId()).toBe("result-units:result");
    const result = document.getElementById("result-units:result")!;
    expect(result.querySelector(".answer-heading")?.textContent).toBe("Unit conversion");
    expect(result.querySelector(".answer-value")?.textContent).toBe("1,000,000,000B");
    expect(result.querySelector(".answer-note")?.textContent).toContain("1,024");
    await key("Enter");
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("1000000000");
    expect(native.hide).not.toHaveBeenCalled();
    expect(native.invoke).not.toHaveBeenCalledWith("get_currency_rates");
    await type("cycle");
    expect(container.querySelector(".instant-answer")).toBeNull();
  });
});

it("opens AI from the toolbar and restores palette focus after Escape", async () => {
  localStorage.setItem("prism.ai.selection.v1", JSON.stringify({ provider: "openai", model: "fixture-model" }));
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation((command: string, args: unknown) => command === "ai_key_status" ? Promise.resolve(true) : command === "ai_get_selection" ? Promise.resolve(JSON.parse(localStorage.getItem("prism.ai.selection.v1") ?? "null")) : original(command, args));
  await mount();
  await click(button("Open AI Chat"));
  await act(async () => { await import("./AiChat"); });
  await settle();
  const composer = container.querySelector<HTMLTextAreaElement>('textarea[aria-label="AI message"]')!;
  expect(composer).not.toBeNull();
  expect(document.activeElement).toBe(composer);
  await key("Escape", { isComposing: true }, composer);
  expect(container.querySelector('section[aria-label="AI Chat"]')).not.toBeNull();
  await key("Escape", {}, composer);
  expect(container.querySelector(".ai-chat")?.hasAttribute("inert")).toBe(true);
  await act(async () => vi.advanceTimersByTime(120));
  expect(container.querySelector('section[aria-label="AI Chat"]')).toBeNull();
  expect(document.activeElement).toBe(input());
  expect(native.hide).not.toHaveBeenCalled();
});

it("opens the native AI settings section from chat without rendering credentials in the palette", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation((command: string, args: unknown) => command === "ai_key_status" ? Promise.resolve(false) : original(command, args));
  await mount(); await click(button("Open AI Chat")); await click(button("Open AI settings"));
  expect(native.invoke).toHaveBeenCalledWith("open_settings_window");
  expect(JSON.parse(localStorage.getItem("prism:settings-navigation")!)).toEqual({ section: "ai" });
  expect(container.querySelector('input[type="password"]')).toBeNull();
});

it("lands directly on AI settings in the separate settings window", async () => {
  localStorage.setItem("prism:settings-navigation", JSON.stringify({ section: "ai" }));
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation((command: string, args: unknown) => {
    if (command === "ai_get_selection") return Promise.resolve(null);
    if (command === "ai_key_info") return Promise.resolve({ configured: false, maskedKey: null });
    if (command === "ai_key_status") return Promise.resolve(false);
    if (command === "ai_list_models") return Promise.resolve([]);
    return original(command, args);
  });
  await mount(true);
  expect(container.querySelector('[role="group"][aria-label="AI provider"]')).not.toBeNull();
  expect(button("AI").getAttribute("aria-current")).toBe("page");
  expect(container.querySelector('input[type="password"]')).not.toBeNull();
});


it("uses plain Tab from root search to expand AI with a draft and restores query on Escape", async () => {
  localStorage.setItem("prism.ai.selection.v1", JSON.stringify({ provider: "openai", model: "fixture-model" }));
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation((command: string, args: unknown) => command === "ai_key_status" ? Promise.resolve(true) : command === "ai_get_selection" ? Promise.resolve(JSON.parse(localStorage.getItem("prism.ai.selection.v1")!)) : original(command, args));
  await mount(); await type("한국어로 설명해 줘");
  await key("Tab", {isComposing:true}); expect(container.querySelector(".ai-chat")).toBeNull();
  expect((await key("Tab", {shiftKey:true})).defaultPrevented).toBe(false);
  await key("Tab");
  expect(container.querySelector("main")?.classList.contains("ai-expanded")).toBe(true);
  expect(container.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe("한국어로 설명해 줘");
  expect(native.invoke).toHaveBeenCalledWith("set_ai_workspace", {expanded:true,reduceMotion:false});
  expect(native.invoke.mock.calls.some(([command])=>command === "ai_chat")).toBe(false);
  await act(async () => window.dispatchEvent(new Event("blur")));
  await key("Escape", {}, container.querySelector("textarea")!);
  await act(async () => vi.advanceTimersByTime(120));
  expect(input().value).toBe("한국어로 설명해 줘"); expect(document.activeElement).toBe(input());
  expect(native.invoke).toHaveBeenCalledWith("set_ai_workspace", {expanded:false,reduceMotion:false});
});

it("changes the entire settings UI from its language selector and restores that choice", async()=>{
 await mount(true);
 await act(async()=>container.querySelector<HTMLButtonElement>('[aria-label="App language"]')!.click());
 await act(async()=>[...document.querySelectorAll<HTMLButtonElement>('[role="option"]')].find(option=>option.textContent === "한국어")!.click());await settle();
 expect(button("일반").getAttribute("aria-current")).toBe("page");
 expect(container.textContent).not.toContain("Prism 전체 화면에 사용할 언어를 선택하세요.");
 expect(container.querySelector('[aria-label="앱 언어"]')).not.toBeNull();
 await click(button("창 관리"));expect(container.textContent).toContain("왼쪽 절반");
 await act(async()=>root.unmount());root=createRoot(container);await mount(true);
 expect(button("일반")).toBeDefined();expect(document.documentElement.lang).toBe("ko");
});
it("searches files directly in the palette with no registered library folders and opens their native ID",async()=>{
 const original=native.invoke.getMockImplementation()!;
 native.invoke.mockImplementation(async(command,args)=>{
  if(command==="library_search_files")return {items:args.query==="작업"?[{id:"spotlight:Documents/작업.md",name:"작업.md".normalize("NFD"),path:"/fixture/Documents/작업.md",isDirectory:false}]:[],total:1,limited:false};
  if(command==="library_file_action")return "/fixture/Documents/작업.md";
  return original(command,args);
 });
 await mount();await type("작업");await act(async()=>{await vi.advanceTimersByTimeAsync(300);});
 expect(selectedId()).toBe("result-file:spotlight:Documents/작업.md");
 expect(document.getElementById(selectedId()!)?.querySelector(".lucide-file-text")).not.toBeNull();
 expect(container.querySelector('[aria-label="Search library"]')).toBeNull();
 await key("Enter");expect(native.invoke).toHaveBeenCalledWith("library_file_action",{id:"spotlight:Documents/작업.md",action:"open"});
});
it("opens snippets and quicklinks directly from their own commands",async()=>{
 await mount();await type("snippet");await key("Enter");
 expect(container.querySelector('.library-heading strong')?.textContent).toBe("Snippets");
 await key("Escape",{},window);await type("links");await key("Enter");
 expect(container.querySelector('.library-heading strong')?.textContent).toBe("Quicklinks");
});
it("applies language notifications from the separate native settings window without clearing the query",async()=>{
 await mount();await type("settings");
 await act(async()=>{
   const preferences = {language:"ko",theme:"dark",commandAliases:{"prism:preferences":"prefs"}};
   localStorage.setItem("prism:preferences", JSON.stringify(preferences));
   native.listeners.get("prism:preferences-changed")!({payload:preferences});
 });await settle();
 expect(input().value).toBe("settings");expect(input().placeholder).toBe("앱, 명령, 파일 검색…");
 expect(container.querySelector('#result-prism\\:preferences')?.textContent).toContain("설정");
 expect(JSON.parse(localStorage.getItem("prism:preferences")!).commandAliases).toEqual({"prism:preferences":"prefs"});
});

it("keeps Prism highlights opt-in and persists them independently of motion settings", async () => {
  await mount(true);
  const highlights = () => container.querySelector<HTMLButtonElement>('[aria-label="Prism highlights"]')!;
  const settings = () => container.querySelector<HTMLElement>('.preferences-v2')!;
  expect(highlights().getAttribute("aria-checked")).toBe("false");
  expect(settings().dataset.prismHighlights).toBe("false");
  await act(async () => highlights().click());
  expect(settings().dataset.prismHighlights).toBe("true");
  const saved = JSON.parse(localStorage.getItem("prism:preferences")!);
  expect(saved.prismHighlights).toBe(true);
  expect(saved.reduceMotion).toBe(false);
  expect(saved.reflectionHighlight).toBe(40);
  await act(async () => { root.unmount(); });
  root = createRoot(container);
  await mount(true);
  expect(highlights().getAttribute("aria-checked")).toBe("true");
  expect(settings().dataset.prismHighlights).toBe("true");
  await act(async () => highlights().click());
  expect(settings().dataset.prismHighlights).toBe("false");
  expect(JSON.parse(localStorage.getItem("prism:preferences")!).prismHighlights).toBe(false);
});

it("persists white edge brightness independently and restores its rendered value", async () => {
  await mount(true);
  const highlight = container.querySelector<HTMLInputElement>('[aria-label="White edge highlight"]')!;
  expect(highlight.value).toBe("40");
  await type("0", highlight);
  expect(document.documentElement.style.getPropertyValue("--reflection-highlight")).toBe("0");
  await type("27", highlight);
  const stored = JSON.parse(localStorage.getItem("prism:preferences")!);
  expect(stored.reflectionHighlight).toBe(27);
  expect(stored.reflectionEdge).toBe(20);
  expect(stored.reflectionIntensity).toBe(65);
  await act(async () => { root.unmount(); });
  root = createRoot(container);
  await mount(true);
  expect(container.querySelector<HTMLInputElement>('[aria-label="White edge highlight"]')!.value).toBe("27");
  expect(document.documentElement.style.getPropertyValue("--reflection-highlight")).toBe("0.27");
});

it("keeps the latest slider values when old storage events and native echoes arrive", async () => {
  await mount(true);
  const opacity = container.querySelector<HTMLInputElement>('[aria-label="Background opacity"]')!;
  const blur = container.querySelector<HTMLInputElement>('[aria-label="Background blur"]')!;
  expect(blur.max).toBe("32");
  const queued: string[] = [];
  for (const [opacityValue, blurValue] of [[40, 0], [55, 8], [70, 16], [85, 24], [94, 32]]) {
    await type(String(opacityValue), opacity);
    await type(String(blurValue), blur);
    queued.push(localStorage.getItem("prism:preferences")!);
  }
  const latest = queued.at(-1)!;
  const writes = vi.spyOn(Storage.prototype, "setItem");
  native.invoke.mockClear();
  try {
    // Simulate both channels delivering a backlog, including our own echoes.
    for (const stale of queued.reverse()) {
      await act(async () => {
        window.dispatchEvent(new StorageEvent("storage", { key: "prism:preferences", newValue: stale, storageArea: localStorage }));
        native.listeners.get("prism:preferences-changed")!({ payload: JSON.parse(stale) });
      });
    }
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    expect(opacity.value).toBe("94");
    expect(blur.value).toBe("32");
    expect(localStorage.getItem("prism:preferences")).toBe(latest);
    expect(writes).not.toHaveBeenCalled();
    expect(native.invoke.mock.calls.filter(([command]) => command === "prepare_window_appearance")).toHaveLength(0);
  } finally { writes.mockRestore(); }
});

it("reads the latest persisted external settings without saving or echoing them", async () => {
  await mount(true);
  const latest = { language: "en", backgroundOpacity: 61, backgroundBlur: 9 };
  localStorage.setItem("prism:preferences", JSON.stringify(latest));
  const writes = vi.spyOn(Storage.prototype, "setItem");
  try {
    await act(async () => {
      window.dispatchEvent(new StorageEvent("storage", {
        key: "prism:preferences", newValue: JSON.stringify({ backgroundOpacity: 20, backgroundBlur: 1 }), storageArea: localStorage,
      }));
    });
    expect(container.querySelector<HTMLInputElement>('[aria-label="Background opacity"]')!.value).toBe("61");
    expect(container.querySelector<HTMLInputElement>('[aria-label="Background blur"]')!.value).toBe("9");
    expect(writes).not.toHaveBeenCalled();
  } finally { writes.mockRestore(); }
});

it.each([36, 44, 240])("limits legacy blur %s without changing the chosen opacity", async (backgroundBlur) => {
  localStorage.setItem("prism:preferences", JSON.stringify({ language: "en", backgroundOpacity: backgroundBlur === 36 ? 94 : 97, backgroundBlur }));
  await mount(true);
  expect(container.querySelector<HTMLInputElement>('[aria-label="Background blur"]')!.value).toBe("32");
  expect(container.querySelector<HTMLInputElement>('[aria-label="Background opacity"]')!.value).toBe(backgroundBlur === 36 ? "94" : "97");
  expect(native.invoke).toHaveBeenCalledWith("prepare_window_appearance", { dark: false, blur: 32 });
});


it("saves full clipboard text as a new snippet and keeps a valid new ID", async () => {
  const original = native.invoke.getMockImplementation()!;
  const fullText = "전체 클립보드 내용 ".repeat(100);
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "get_clipboard_history_entry_text") return fullText;
    if (command === "library_save_entry") return;
    return original(command, args);
  });
  await mount(); await type("clipboard"); await key("Enter");
  await key("k", {ctrlKey:true});
  const search = container.querySelector<HTMLInputElement>('[aria-label="Search actions"]')!;
  await type("Save as Snippet", search); await key("Enter", {}, search);
  expect(container.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe(fullText);
  expect(native.invoke).not.toHaveBeenCalledWith("library_save_entry", expect.anything());
  await click(button("Save"));
  expect(native.invoke).toHaveBeenCalledWith("library_save_entry", {entry:expect.objectContaining({id:expect.stringMatching(/.+/),kind:"snippet",value:fullText})});
});

it("pins clipboard history without launching or hiding another command", async () => {
  const original = native.invoke.getMockImplementation()!;
  let pinned = false;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "search_clipboard_history") return [{id:1,text:"Fixture",capturedAt:1,pinned}];
    if (command === "set_clipboard_history_entry_pinned") { pinned = args.pinned; return; }
    return original(command,args);
  });
  await mount(); await type("clipboard"); await key("Enter"); await key("k",{ctrlKey:true});
  const search = container.querySelector<HTMLInputElement>('[aria-label="Search actions"]')!;
  await type("Pin entry",search); await key("Enter",{},search);
  expect(native.invoke).toHaveBeenCalledWith("set_clipboard_history_entry_pinned",{id:1,pinned:true});
  expect(container.querySelector('[aria-label="Pinned"]')).not.toBeNull();
  expect(native.hide).not.toHaveBeenCalled();
});

it("opens script arguments without execution and returns to the palette with Escape", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command,args) => {
    if (command === "list_script_commands") return [{id:"fixture-argument",title:"Fixture automation",keywords:[],arguments:[{type:"text",placeholder:"Search term"}]}];
    return original(command,args);
  });
  await mount(); await type("Fixture automation"); await key("Enter");
  const field = container.querySelector<HTMLInputElement>('[aria-label="Search term"]')!;
  expect(field).not.toBeNull();
  expect(native.invoke).not.toHaveBeenCalledWith("start_script_command",expect.anything());
  await key("Escape",{isComposing:true},field);
  expect(container.querySelector('[aria-label="Search term"]')).not.toBeNull();
  await key("Escape",{},field);
  expect(document.activeElement).toBe(input());
});

it("starts a zero-argument script once from Enter and shows its output", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command,args) => {
    if (command === "list_script_commands") return [{id:"fixture-zero",title:"Fixture zero arguments",keywords:[]}];
    if (command === "start_script_command") return {runId:"fixture-run",state:"success",result:null,error:null,stdout:"Completed fixture",stderr:"",stdoutTruncated:false,stderrTruncated:false};
    return original(command,args);
  });
  await mount(); await type("Fixture zero arguments"); await key("Enter");
  expect(native.invoke.mock.calls.filter(([command])=>command === "start_script_command")).toEqual([["start_script_command",{scriptId:"fixture-zero",args:[]}]]);
  expect(container.textContent).toContain("Completed fixture");
  expect(container.textContent).toContain("Script succeeded");
});


it("opens the visual emoji picker from Korean search and copies an exact emoji through native IPC", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => command === "copy_plain_text" ? undefined : original(command, args));
  await mount(); await type("이모지"); await key("Enter"); await settle();
  expect(container.querySelector('[aria-label="Search emoji"]')).not.toBeNull();
  expect(container.querySelectorAll('[role="gridcell"]').length).toBeGreaterThan(100);
  await click(button("grinning face"));
  expect(native.invoke).toHaveBeenCalledWith("copy_plain_text", { text: "😀" });
  expect(container.textContent).toContain("Copied");
  expect(native.hide).not.toHaveBeenCalled();
  await key("Escape");
  expect(container.querySelector(".emoji-picker")).toBeNull();
  expect(document.activeElement).toBe(input());
});

it("keeps a failed emoji paste open for an exact copy fallback without executing the root palette", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "paste_plain_text") throw new Error("Original app is unavailable");
    if (command === "copy_plain_text") return;
    return original(command, args);
  });
  await mount(); await type("emoji"); await key("Enter"); await settle();
  await click(button("Paste")); await click(button("grinning face"));
  expect(container.querySelector(".emoji-picker")).not.toBeNull();
  expect(container.textContent).toContain("Original app is unavailable");
  expect(native.invoke.mock.calls.filter(([name]) => name === "paste_plain_text")).toHaveLength(1);
  await click(button("Copy instead"));
  expect(native.invoke).toHaveBeenCalledWith("copy_plain_text", { text: "😀" });
  expect(container.textContent).toContain("Copied");
  expect(native.hide).not.toHaveBeenCalled();
});

it("opens broader file search with the original query and system scope enabled", async () => {
  await mount(); await type("quarterly report");
  await click(document.getElementById("result-files:search-broader")!);
  expect(container.querySelector<HTMLInputElement>('[aria-label="Search library"]')?.value).toBe("quarterly report");
  expect(native.invoke.mock.calls.some(([name, args]) => name === "library_search_files" && args.query === "quarterly report" && args.includeSystem === true)).toBe(true);
});

it("copies an exact local calendar calculation through native IPC", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => command === "copy_plain_text" ? undefined : original(command, args));
  await mount(); await type("2026-09-06 + 3 days");
  expect(container.querySelector(".instant-answer")?.textContent).toContain("2026-09-09");
  await key("Enter");
  expect(native.invoke).toHaveBeenCalledWith("copy_plain_text", { text: "2026-09-09" });
});

it("preserves malformed settings across mounting and external preference notifications", async () => {
  const original = "{ damaged preferences";
  localStorage.setItem("prism:preferences", original);
  await mount();
  expect(container.textContent).toContain("Settings could not be read. Temporary defaults are in use.");
  await act(async () => { native.listeners.get("prism:preferences-changed")!({ payload: { language: "ko" } }); });
  await settle();
  expect(localStorage.getItem("prism:preferences")).toBe(original);
  expect(localStorage.getItem("prism:preferences:before-recovery:v1")).toBeNull();
});

it("filters rich clipboard entries and loads the selected image metadata and thumbnail", async () => {
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "search_clipboard_history") return [{ id: 2, text: "Image fixture", capturedAtMs: 1, kind: "image", mimeType: "image/png", width: 20, height: 10, byteSize: 400 }];
    if (command === "get_clipboard_history_entry_preview") return "data:image/png;base64,fixture";
    return original(command, args);
  });
  await mount(); await type("clipboard"); await key("Enter");
  const filter = container.querySelector<HTMLSelectElement>('[aria-label="Clipboard type"]')!;
  await act(async () => { filter.value = "image"; filter.dispatchEvent(new Event("change", { bubbles: true })); });
  await settle();
  expect(native.invoke.mock.calls.some(([name, args]) => name === "search_clipboard_history" && args.kind === "image")).toBe(true);
  expect(container.querySelector(".clipboard-selection-preview")?.textContent).toContain("20 × 10 · image/png");
  expect(container.querySelector('.clipboard-selection-preview img')?.getAttribute("src")).toBe("data:image/png;base64,fixture");
});


it("selects clipboard rows without copying and shows complete multiline text in the detail pane", async () => {
  const fullText = "한국어 긴 내용\n".repeat(200);
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "search_clipboard_history") return [
      { id: 1, text: "First entry", capturedAtMs: 1, kind: "text" },
      { id: 2, text: fullText.slice(0, 500), capturedAtMs: 2, kind: "text" },
    ];
    if (command === "get_clipboard_history_entry_text") return args.id === 2 ? fullText : "First entry";
    if (command === "copy_clipboard_history_entry") return;
    return original(command, args);
  });
  await mount(); await type("clipboard"); await key("Enter");
  await click(document.getElementById("result-clipboard:entry:2")!);
  expect(selectedId()).toBe("result-clipboard:entry:2");
  expect(container.querySelector(".clipboard-preview-content")?.textContent).toBe(fullText);
  expect(native.invoke.mock.calls.some(([name]) => name === "copy_clipboard_history_entry")).toBe(false);
  await key("Enter");
  expect(native.invoke).toHaveBeenCalledWith("copy_clipboard_history_entry", { id: 2 });
});
