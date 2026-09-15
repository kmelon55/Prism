import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ClipboardSettings } from "./ClipboardSettings";
import type { ClipboardSettingsState } from "../providers/clipboard";
import { getClipboardHistoryEntryText, searchDurableClipboardHistory, setClipboardHistoryEntryPinned } from "../providers/clipboard";

const mocks = vi.hoisted(() => ({ invoke: vi.fn(), notify: vi.fn(), clear: vi.fn(), enabled: vi.fn(), native: true }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("../providers/native", () => ({
  isTauriRuntime: () => mocks.native,
  searchNativeApplications: async () => [{id:"fixture-app",name:"Fixture App",path:"/Applications/Fixture.app",platform:"macos",rankingBoost:0}],
  clearClipboardHistory: mocks.clear,
  setClipboardHistoryEnabled: mocks.enabled,
  emitClipboardHistorySettingChanged: mocks.notify,
  onClipboardHistorySettingChanged: async () => () => undefined,
}));
let root: Root;
let container: HTMLDivElement;
let state: ClipboardSettingsState;
beforeEach(() => {
  vi.clearAllMocks(); mocks.native = true;
  localStorage.setItem("prism:preferences", JSON.stringify({ language: "en", clipboardHistoryEnabled: true }));
  state = { enabled: true, retentionDays: 30, entryCount: 3, pinnedCount: 1, capacity: 1000, persistenceError: null };
  mocks.invoke.mockImplementation(async (command: string, args?: { retentionDays: 1 | 7 | 30 | 90 }) => {
    if (command === "set_clipboard_history_retention") state = { ...state, retentionDays: args!.retentionDays };
    return { ...state };
  });
  mocks.enabled.mockImplementation(async (enabled: boolean) => { state = { ...state, enabled, entryCount: enabled ? state.entryCount : 0 }; return enabled; });
  mocks.clear.mockImplementation(async () => { state = { ...state, entryCount: 0, pinnedCount: 0 }; return 3; });
  mocks.notify.mockResolvedValue(undefined);
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount() { await act(async () => root.render(<StrictMode><ClipboardSettings /></StrictMode>)); }
async function click(label: string) {
  const button = [...container.querySelectorAll("button")].find((item) => item.textContent?.trim() === label || item.getAttribute("aria-label") === label);
  expect(button, label).toBeDefined();
  await act(async () => button!.click());
}
async function retention(value: string) {
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Keep history for"]')!.click());
  const index = ["1","7","30","90"].indexOf(value);
  await act(async () => document.querySelectorAll<HTMLButtonElement>('[role="option"]')[index].click());
}

describe("durable clipboard settings", () => {
  it("uses native consent instead of stale browser preferences and makes no browser capture calls", async () => {
    state.enabled = false; await mount();
    expect(container.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("false");
    expect(mocks.enabled).not.toHaveBeenCalled();
    await click("Enable clipboard history");
    expect(mocks.enabled).toHaveBeenCalledWith(true);
    expect(mocks.notify).toHaveBeenCalledWith(true);
  });
  it("requires explicit confirmation to disable or clear pins and preserves enablement when clearing", async () => {
    await mount(); await click("Enable clipboard history");
    expect(mocks.enabled).not.toHaveBeenCalled();
    expect(container.querySelector('[role="alertdialog"]')?.textContent).toContain("including pins");
    await click("Cancel"); expect(mocks.enabled).not.toHaveBeenCalled();
    await click("Clear history"); expect(mocks.clear).not.toHaveBeenCalled();
    await click("Confirm"); expect(mocks.clear).toHaveBeenCalledTimes(1);
    expect(state.enabled).toBe(true);
    await click("Enable clipboard history"); await click("Confirm");
    expect(mocks.enabled).toHaveBeenCalledWith(false);
  });
  it("confirms destructive retention shortening but applies a longer period directly", async () => {
    await mount(); await retention("7");
    expect(mocks.invoke).not.toHaveBeenCalledWith("set_clipboard_history_retention", expect.anything());
    await click("Confirm");
    expect(mocks.invoke).toHaveBeenCalledWith("set_clipboard_history_retention", { retentionDays: 7 });
    await retention("90");
    expect(mocks.invoke).toHaveBeenCalledWith("set_clipboard_history_retention", { retentionDays: 90 });
  });
  it("retries failed clear with confirmation and never toggles capture as a retry", async () => {
    mocks.clear.mockRejectedValueOnce("Disk full");
    await mount(); await click("Clear history"); await click("Confirm");
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Disk full");
    expect(state.entryCount).toBe(3);
    await click("Retry"); expect(mocks.clear).toHaveBeenCalledTimes(1);
    await click("Confirm"); expect(mocks.clear).toHaveBeenCalledTimes(2);
    expect(mocks.enabled).not.toHaveBeenCalled();
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });
  it("does not treat a notification failure as a failed deletion", async () => {
    mocks.notify.mockRejectedValueOnce("Window unavailable");
    await mount(); await click("Clear history"); await click("Confirm");
    expect(mocks.clear).toHaveBeenCalledTimes(1);
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });
  it("shows startup storage errors and disables browser-only controls", async () => {
    state.persistenceError = "Storage unavailable"; await mount();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Storage unavailable");
    await act(async () => root.unmount()); root = createRoot(container);
    mocks.native = false; mocks.invoke.mockClear(); await mount();
    expect(mocks.invoke).not.toHaveBeenCalled();
    expect(container.querySelector<HTMLButtonElement>('[role="switch"]')!.disabled).toBe(true);
    expect(container.textContent).toContain("desktop app");
  });
});

describe("clipboard pin and snippet provider contracts", () => {
  it("preserves pin metadata and retrieves complete text independently of a truncated preview", async () => {
    const fullText = "메모".repeat(500);
    mocks.invoke.mockImplementation(async (command: string) => command === "search_clipboard_history" ? [{ id: 42, text: "메모…", capturedAtMs: 100, pinned: true }] : command === "get_clipboard_history_entry_text" ? fullText : undefined);
    expect(await searchDurableClipboardHistory("메모")).toEqual([{ id: 42, content: "메모…", capturedAt: 100, pinned: true }]);
    expect(await getClipboardHistoryEntryText(42)).toBe(fullText);
    await setClipboardHistoryEntryPinned(42, false);
    expect(mocks.invoke).toHaveBeenCalledWith("set_clipboard_history_entry_pinned", { id: 42, pinned: false });
  });
});


it("saves Return and pause options without clearing retained entries", async () => {
  const original = mocks.invoke.getMockImplementation()!;
  mocks.invoke.mockImplementation(async (command, args) => {
    if (command === "set_clipboard_primary_action") state = {...state, primaryAction: args.action};
    if (command === "set_clipboard_capture_pause") state = {...state, pausedUntilMs: args.minutes ? Date.now()+args.minutes*60000 : 0};
    return original(command,args);
  });
  await mount();
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Return action"]')!.click());
  await act(async () => [...document.querySelectorAll<HTMLButtonElement>('[role="option"]')].find(option => option.textContent === "Copy to Clipboard")!.click());
  expect(mocks.invoke).toHaveBeenCalledWith("set_clipboard_primary_action", {action:"copy"});
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Pause recording"]')!.click());
  await act(async () => [...document.querySelectorAll<HTMLButtonElement>('[role="option"]')].find(option => option.textContent === "Pause for 15 minutes")!.click());
  expect(mocks.invoke).toHaveBeenCalledWith("set_clipboard_capture_pause", {minutes:15});
  expect(container.textContent).toContain("Recording paused until");
  expect(state.entryCount).toBe(3); expect(state.pinnedCount).toBe(1);
  expect(mocks.clear).not.toHaveBeenCalled(); expect(mocks.enabled).not.toHaveBeenCalled();
});

it("adds and removes an excluded app without deleting existing history", async () => {
  const original = mocks.invoke.getMockImplementation()!;
  mocks.invoke.mockImplementation(async (command,args) => {
    if (command === "add_clipboard_excluded_application") state = {...state,excludedApplications:[{id:"org.fixture",name:"Fixture App"}]};
    if (command === "remove_clipboard_excluded_application") state = {...state,excludedApplications:[]};
    return original(command,args);
  });
  await mount();
  const field=container.querySelector<HTMLInputElement>('[aria-label="Search applications to exclude"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value")!.set!.call(field,"Fixture");
    field.dispatchEvent(new Event("input",{bubbles:true}));
  });
  await act(async () => { await new Promise(resolve=>setTimeout(resolve,160)); });
  await click("Exclude Fixture App");
  expect(mocks.invoke).toHaveBeenCalledWith("add_clipboard_excluded_application", {path:"/Applications/Fixture.app"});
  expect(container.textContent).toContain("org.fixture");
  await click("Stop excluding Fixture App");
  expect(mocks.invoke).toHaveBeenCalledWith("remove_clipboard_excluded_application", {id:"org.fixture"});
  expect(mocks.clear).not.toHaveBeenCalled(); expect(state.entryCount).toBe(3);
});
