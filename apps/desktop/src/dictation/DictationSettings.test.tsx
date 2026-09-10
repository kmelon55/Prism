import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { DictationSettings } from "./DictationSettings";
import { changeProvider, defaultSettings } from "./api";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn(async () => () => {}) }));
let root: Root;
let container: HTMLDivElement;
let settings = changeProvider(defaultSettings, "openai");
const state = { phase: "idle", message: "", microphone: "granted", accessibility: true, hasTranscript: false };
beforeEach(() => {
  localStorage.clear(); Object.defineProperty(navigator, "language", { configurable: true, value: "en-US" });
  settings = changeProvider(defaultSettings, "openai");
  invoke.mockReset().mockImplementation(async (command, args) => {
    if (command === "dictation_get_settings") return settings;
    if (command === "dictation_action") return state;
    if (command === "dictation_key_info" || command === "dictation_save_key") return { configured: true, maskedKey: "•••• •••• 1234", unlocked: true };
    if (command === "dictation_list_models") return { models: [{ id: "whisper-large-v3-turbo", name: "whisper-large-v3-turbo", description: "", ownedBy: "groq", batchCompatible: true, pricing: null }], source: "fixture", mode: "catalog" };
    if (command === "dictation_save_settings") return args.settings;
  });
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount(nativeRuntime = true) { await act(async () => root.render(<DictationSettings nativeRuntime={nativeRuntime} shortcut={<span>Shared shortcut recorder</span>} onPermissions={() => {}} />)); }
function button(label: string) { const result = [...container.querySelectorAll("button")].find(button => button.textContent?.trim() === label); expect(result, label).toBeDefined(); return result!; }
async function click(label: string) {
  if (["Groq", "Vercel AI Gateway"].includes(label) && !container.querySelector('[role="dialog"]')) await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Change dictation model"]')!.click());
  await act(async () => button(label === "Vercel AI Gateway" ? "Vercel" : label).click());
}
async function type(input: HTMLInputElement, value: string) { await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); }); }
it("switches the provider's endpoint/model together and saves no credentials", async () => {
  await mount(); await click("Groq");
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 20)); });
  await act(async () => container.querySelector<HTMLButtonElement>(".dictation-model")!.click());
  await click("Save");
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings", { settings: expect.objectContaining({ provider: "groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", uiLanguage: "en" }) });
  expect(invoke.mock.calls.find(([command]) => command === "dictation_save_settings")?.[1].settings).not.toHaveProperty("apiKey");
  expect(invoke).not.toHaveBeenCalledWith("dictation_toggle");
});
it("keeps a masked shared key after saving and clears the editor on provider change", async () => {
  await mount(); await click("Change");
  const input = container.querySelector<HTMLInputElement>('input[type="password"]')!;
  await type(input, "fixture-secret"); await click("Save key");
  expect(invoke).toHaveBeenCalledWith("dictation_save_key", { provider: "openai", key: "fixture-secret" });
  expect(container.querySelector('input[type="password"]')).toBeNull();
  expect(container.querySelector(".dictation-saved-key")?.textContent).toContain("•••• •••• 1234");
  await click("Change"); await type(container.querySelector<HTMLInputElement>('input[type="password"]')!, "unsaved-secret"); await click("Vercel AI Gateway");
  expect(container.querySelector('input[type="password"]')).toBeNull(); expect(localStorage.length).toBe(0);
});
it("requires confirmation before removing the shared AI key", async () => {
  await mount(); await click("Delete key");
  expect(container.textContent).toContain("Deleting this key also removes it from AI chat.");
  expect(invoke.mock.calls.some(([command]) => command === "dictation_delete_key")).toBe(false);
  await click("Confirm Clear"); expect(invoke).toHaveBeenCalledWith("dictation_delete_key", { provider: "openai" });
});
it("previews without recording or transcription and disables native actions in browser", async () => {
  await mount(); await click("Preview waveform");
  expect(invoke).toHaveBeenCalledWith("dictation_action", { action: "preview", previewSettings: expect.objectContaining({ showRecordingShortcutHints: true, showTranscriptionStatus: true }) });
  expect(invoke.mock.calls.some(([command]) => command === "dictation_toggle")).toBe(false);
  await mount(false); expect(button("Preview waveform").disabled).toBe(true);
});
it("keeps unsaved settings reviewable after a failed write", async () => {
  await mount(); await click("Groq");
  const original = invoke.getMockImplementation()!;
  invoke.mockImplementation(async (command, args) => { if (command === "dictation_save_settings") throw new Error("disk full"); return original(command, args); });
  await click("Save");
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("disk full");
  expect(button("Save").disabled).toBe(false);
});

it("keeps provider/model selection in the right-hand popover and saves on selection", async () => {
  await mount(); expect(container.querySelector('[role="dialog"]')).toBeNull(); expect(container.querySelector(".dictation-model")).toBeNull();
  await click("Groq"); await act(async () => { await new Promise(resolve => setTimeout(resolve, 20)); });
  await act(async () => container.querySelector<HTMLButtonElement>(".dictation-model")!.click());
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  expect(container.querySelector(".ai-current-model-copy")?.textContent).toContain("whisper-large-v3-turbo");
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings", { settings: expect.objectContaining({ provider: "groq", model: "whisper-large-v3-turbo" }) });
});
it("previews the two independent Whisp overlay switches before saving", async () => {
  await mount();
  await act(async () => container.querySelector<HTMLButtonElement>('[role="switch"][aria-label="Recording shortcut hints"]')!.click());
  await click("Preview waveform");
  expect(invoke).toHaveBeenLastCalledWith("dictation_action", { action: "preview", previewSettings: expect.objectContaining({ showRecordingShortcutHints: false, showTranscriptionStatus: true }) });
  expect(invoke.mock.calls.some(([command]) => command === "dictation_save_settings")).toBe(false);
});

it("saves delivery shortcuts beside the recorder without committing an unrelated provider draft", async () => {
  await mount(); await click("Groq");
  const select = container.querySelector<HTMLSelectElement>('[aria-label="Default result action"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, "copy");
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  expect(button("Save shortcut").disabled).toBe(false);
  await click("Save shortcut");
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings", { settings: expect.objectContaining({ provider: "openai", defaultDelivery: "copy" }) });
  expect(button("Save shortcut").disabled).toBe(true);
  expect(button("Save").disabled).toBe(false);
});
