import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { DictationApiKey } from "./DictationApiKey";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn(async () => () => {}) }));
const absent = { configured: false, maskedKey: null };
const saved = { configured: true, maskedKey: "•••• •••• 1234", unlocked: true };
let element: HTMLDivElement;
let root: Root;
const configured = vi.fn();
beforeEach(() => {
  localStorage.clear(); Object.defineProperty(navigator, "language", { configurable: true, value: "en-US" });
  configured.mockClear(); invoke.mockReset().mockResolvedValue(absent);
  element = document.createElement("div"); document.body.append(element); root = createRoot(element);
});
afterEach(async () => { await act(async () => root.unmount()); element.remove(); });
async function mount(provider = "groq") { await act(async () => root.render(<DictationApiKey key={provider} provider={provider} nativeRuntime disabled={false} onConfigured={configured} />)); }
function input() { return element.querySelector<HTMLInputElement>('input[type="password"]')!; }
async function type(value: string) { await act(async () => {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input(), value);
  input().dispatchEvent(new Event("input", { bubbles: true }));
}); }
async function click(label: string) { await act(async () => {
  const button = [...element.querySelectorAll("button")].find(button => button.textContent === label);
  expect(button, label).toBeDefined(); button!.click();
}); }
async function focus() { await act(async () => { window.dispatchEvent(new Event("focus")); }); }

it("preserves an unsaved key through focus and catalog notifications", async () => {
  await mount(); await type("fixture-draft-secret"); await focus();
  await act(async () => { window.dispatchEvent(new Event("prism:ai-settings-changed")); });
  expect(input().value).toBe("fixture-draft-secret");
  expect(invoke.mock.calls.every(([command]) => command === "dictation_key_info")).toBe(true);
});

it("requests Keychain authorization only after Allow key use is clicked", async () => {
  invoke.mockResolvedValue({ configured: true, maskedKey: null, unlocked: false });
  await mount(); await focus();
  expect(invoke.mock.calls.every(([command]) => command === "dictation_key_info")).toBe(true);
  invoke.mockResolvedValue(saved);
  await click("Allow key use");
  expect(invoke).toHaveBeenCalledWith("dictation_unlock_key", { provider: "groq" });
  expect(element.textContent).not.toContain("Allow key use");
  expect(element.querySelector("code")?.textContent).toBe(saved.maskedKey);
});

it("does not retry a canceled authorization on focus or status refresh", async () => {
  const locked = { configured: true, maskedKey: null, unlocked: false };
  invoke.mockImplementation(command => command === "dictation_unlock_key" ? Promise.reject("Authorization canceled") : Promise.resolve(locked));
  await mount(); await click("Allow key use"); await focus();
  await act(async () => { window.dispatchEvent(new Event("prism:ai-settings-changed")); });
  expect(invoke.mock.calls.filter(([command]) => command === "dictation_unlock_key")).toHaveLength(1);
});

it("keeps the acknowledged masked key visible through refresh and remount", async () => {
  await mount(); await type("fixture-secret-1234");
  invoke.mockResolvedValue(saved);
  await click("Save key");
  expect(input()).toBeNull();
  expect(element.querySelector("code")?.textContent).toBe(saved.maskedKey);
  expect(element.textContent).not.toContain("fixture-secret");
  await focus(); expect(element.querySelector("code")?.textContent).toBe(saved.maskedKey);
  await act(async () => root.render(null)); await mount();
  expect(element.querySelector("code")?.textContent).toBe(saved.maskedKey);
  expect(configured).toHaveBeenLastCalledWith(true);
  expect(localStorage.length).toBe(0);
});

it("does not let an older absent-key response erase a successful write", async () => {
  let resolveRead!: (value: typeof absent) => void;
  invoke.mockImplementation(command => command === "dictation_key_info" ? new Promise(resolve => { resolveRead = resolve; }) : Promise.resolve(saved));
  await mount(); await type("fixture-secret-1234"); await click("Save key");
  await act(async () => resolveRead(absent));
  expect(element.querySelector("code")?.textContent).toBe(saved.maskedKey);
  expect(configured).toHaveBeenLastCalledWith(true);
});

it("retains the previous key and replacement draft on failed save or status lookup", async () => {
  invoke.mockResolvedValue(saved); await mount(); await click("Change"); await type("replacement-fixture");
  invoke.mockRejectedValue("Keychain unavailable"); await click("Save key");
  expect(input().value).toBe("replacement-fixture");
  expect(element.querySelector("code")?.textContent).toBe(saved.maskedKey);
  expect(element.querySelector('[role="alert"]')?.textContent).toContain("Keychain unavailable");
  await focus(); expect(input().value).toBe("replacement-fixture");
  expect(configured).toHaveBeenLastCalledWith(true);
});

it("ignores a previous provider's late response and never shows an unmasked locked key", async () => {
  let resolveRead!: (value: typeof saved) => void;
  invoke.mockImplementation((_command, { provider }) => provider === "groq" ? new Promise(resolve => { resolveRead = resolve; }) : Promise.resolve({ configured: true, maskedKey: null, unlocked: false }));
  await mount(); await type("discard-this-draft"); await mount("openai");
  await act(async () => resolveRead(saved));
  expect(input()).toBeNull();
  expect(element.querySelector("code")?.textContent).toBe("•••• ••••");
  expect(element.textContent).not.toContain("1234");
});
