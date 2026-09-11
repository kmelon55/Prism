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
    if (command === "ai_list_models") return [{id:"fixture/text",name:"Fixture text",inputPrice:.1,outputPrice:.2}];
    if (command === "dictation_action") return state;
    if (command === "ai_usage_summary") { const totals = { requests: 0, inputTokens: 0, outputTokens: 0, knownCostUsd: 0, unknownCostRequests: 0, unknownTokenRequests: 0, estimatedRequests: 0 }; return { month: totals, allTime: totals, features: [], recent: [] }; }
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
  await mount();
  const original = invoke.getMockImplementation()!;
  invoke.mockImplementation(async (command, args) => { if (command === "dictation_save_settings") throw new Error("disk full"); return original(command, args); });
  await click("English");
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("disk full");
  expect(button("Retry").disabled).toBe(false);
});

it("keeps provider/model selection in the right-hand popover and saves on selection", async () => {
  await mount(); expect(container.querySelector('[role="dialog"]')).toBeNull(); expect(container.querySelector(".dictation-model")).toBeNull();
  await click("Groq"); await act(async () => { await new Promise(resolve => setTimeout(resolve, 20)); });
  await act(async () => container.querySelector<HTMLButtonElement>(".dictation-model")!.click());
  expect(container.querySelector('[role="dialog"]:not([inert])')).toBeNull();
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 250)); });
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  expect(container.querySelector(".ai-current-model-copy")?.textContent).toContain("whisper-large-v3-turbo");
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings", { settings: expect.objectContaining({ provider: "groq", model: "whisper-large-v3-turbo" }) });
});
it("automatically saves the overlay switches and previews their current values", async () => {
  await mount();
  await act(async () => container.querySelector<HTMLButtonElement>('[role="switch"][aria-label="Recording shortcut hints"]')!.click());
  await click("Preview waveform");
  expect(invoke).toHaveBeenLastCalledWith("dictation_action", { action: "preview", previewSettings: expect.objectContaining({ showRecordingShortcutHints: false, showTranscriptionStatus: true }) });
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings", { settings: expect.objectContaining({ showRecordingShortcutHints: false, showTranscriptionStatus: true }) });
});

it("saves delivery shortcuts beside the recorder without committing an unrelated provider draft", async () => {
  await mount(); await click("Groq");
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Default result action"]')!.click());
  await act(async () => [...document.querySelectorAll<HTMLButtonElement>('[role="option"]')].find(option => option.textContent === "Copy to clipboard only")!.click());
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings", { settings: expect.objectContaining({ provider: "openai", defaultDelivery: "copy" }) });
  expect([...container.querySelectorAll("button")].some(button => ["Save", "Save shortcut"].includes(button.textContent ?? ""))).toBe(false);
});

it("flushes text on leaving settings and restores it when reopened", async () => {
  const original = invoke.getMockImplementation()!;
  invoke.mockImplementation(async (command, args) => {
    if (command === "dictation_save_settings") { settings = args.settings; return settings; }
    return original(command, args);
  });
  await mount();
  const input = container.querySelector<HTMLTextAreaElement>(".dictation-advanced textarea")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, "Prism 한국어");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  expect(invoke.mock.calls.some(([command]) => command === "dictation_save_settings")).toBe(false);
  await act(async () => root.render(null));
  expect(settings.prompt).toBe("Prism 한국어");
  await mount();
  expect(container.querySelector<HTMLTextAreaElement>(".dictation-advanced textarea")!.value).toBe("Prism 한국어");
});

it("independently enables both enhancements and retains both profiles", async () => {
  settings = {...settings, cleanupModel:{provider:"vercel",model:"fixture/cleanup"},promptModel:{provider:"openai",model:"fixture/prompt"},cleanupInstruction:"Keep technical terms",promptInstruction:"Use short paragraphs"};
  await mount();
  const cleanup = container.querySelector<HTMLButtonElement>('[aria-label="Refine speech"]')!;
  const prompt = container.querySelector<HTMLButtonElement>('[aria-label="Structure prompt"]')!;
  await act(async () => cleanup.click());
  expect(cleanup.getAttribute("aria-checked")).toBe("true");
  await act(async () => prompt.click());
  expect(cleanup.getAttribute("aria-checked")).toBe("true");
  expect(prompt.getAttribute("aria-checked")).toBe("true");
  expect(invoke).toHaveBeenLastCalledWith("dictation_save_settings", { settings: expect.objectContaining({ enhancementMode: "both", refineText: true }) });
  expect(container.querySelector(".dictation-prompt-shortcut")).not.toBeNull();
  await act(async () => prompt.click());
  expect(prompt.getAttribute("aria-checked")).toBe("false");
  expect(container.querySelector(".dictation-prompt-shortcut")).toBeNull();
  expect(cleanup.getAttribute("aria-checked")).toBe("true");
  await act(async () => cleanup.click());
  expect(cleanup.getAttribute("aria-checked")).toBe("false");
  expect(invoke).toHaveBeenLastCalledWith("dictation_save_settings", {settings:expect.objectContaining({enhancementMode:"off",refineText:false,cleanupModel:settings.cleanupModel,promptModel:settings.promptModel,cleanupInstruction:settings.cleanupInstruction,promptInstruction:settings.promptInstruction})});
  expect(invoke.mock.calls.some(([command])=>command === "ai_send" || command === "dictation_toggle")).toBe(false);
});
it("keeps local file controls inside the model selector and usage in the AI tab", async () => {
  settings = changeProvider(defaultSettings,"local");
  await mount();
  expect(container.querySelector('[aria-label="Local model file"]')).toBeNull();
  expect(container.querySelector('.ai-usage')).toBeNull();
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Change dictation model"]')!.click());
  expect(container.querySelector('[role="dialog"] input[aria-label="Local model file"]')).not.toBeNull();
});

it("edits only the chosen profile model and prompt", async () => {
  settings={...settings,enhancementMode:"prompt",promptModel:{provider:"openai",model:"keep/prompt"},promptInstruction:"Keep this prompt"};
  await mount();
  const cleanup=container.querySelector('.dictation-processing-option')!;
  await act(async()=>cleanup.querySelector<HTMLButtonElement>('.ai-model-trigger')!.click());
  await act(async()=>cleanup.querySelector<HTMLButtonElement>('.ai-picker-results > button')!.click());
  expect(invoke).toHaveBeenCalledWith("dictation_save_settings",{settings:expect.objectContaining({cleanupModel:{provider:"vercel",model:"fixture/text",modelName:"Fixture text"},promptModel:settings.promptModel,enhancementMode:"prompt"})});
  const textarea=cleanup.querySelector('textarea')!;
  await act(async()=>{Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,"value")!.set!.call(textarea,"Preserve names exactly.");textarea.dispatchEvent(new Event("input",{bubbles:true}));});
  await act(async()=>root.render(null));
  expect(invoke).toHaveBeenLastCalledWith("dictation_save_settings",{settings:expect.objectContaining({cleanupInstruction:"Preserve names exactly.",promptInstruction:"Keep this prompt"})});
});

it("does not replace a working remote provider while browsing an incomplete local model", async () => {
  await mount();
  await act(async()=>container.querySelector<HTMLButtonElement>('[aria-label="Change dictation model"]')!.click());
  await act(async()=>[...container.querySelectorAll<HTMLButtonElement>('.ai-picker-providers button')].find(button=>button.textContent?.startsWith("Local"))!.click());
  expect(container.querySelector('[role="dialog"] input[aria-label="Local model file"]')).not.toBeNull();
  expect(invoke).toHaveBeenLastCalledWith("dictation_save_settings",{settings:expect.objectContaining({provider:"openai",model:settings.model})});
});

it("opens durable recovery without starting another transcription", async () => {
  await mount(); await click("Open recovery folder");
  expect(invoke).toHaveBeenCalledWith("dictation_action", { action: "openRecovery" });
  expect(invoke.mock.calls.some(([command]) => command === "dictation_toggle")).toBe(false);
  await mount(false); expect(button("Open recovery folder").disabled).toBe(true);
});

it("persists the dictation history switch independently and restores it on reopening", async () => {
  const original = invoke.getMockImplementation()!;
  invoke.mockImplementation(async (command, args) => {
    if (command === "dictation_save_settings") { settings = args.settings; return settings; }
    return original(command, args);
  });
  const toggle = () => container.querySelector<HTMLButtonElement>('[role="switch"][aria-label="Save dictation results to clipboard history"]')!;
  await mount();
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  await act(async () => toggle().click());
  expect(settings.saveToClipboardHistory).toBe(false);
  expect(settings.defaultDelivery).toBe("paste");
  await act(async () => root.render(null));
  await mount();
  expect(toggle().getAttribute("aria-checked")).toBe("false");
  await act(async () => toggle().click());
  expect(settings.saveToClipboardHistory).toBe(true);
  expect(invoke.mock.calls.some(([command]) => command === "dictation_toggle")).toBe(false);
});
