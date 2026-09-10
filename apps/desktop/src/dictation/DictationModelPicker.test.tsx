import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { DictationModelPicker, modelPrice, type DictationCatalog, type DictationModel } from "./DictationModelPicker";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
let root: Root; let container: HTMLDivElement;
const select = vi.fn();
const entry = (id: string, batchCompatible = true): DictationModel => ({ id, name: id, description: "", ownedBy: "", batchCompatible, unavailableReason: batchCompatible ? null : "실시간 전용 모델", free: false, pricing: null });
const catalog = (...models: DictationModel[]): DictationCatalog => ({ models, source: "fixture", mode: "catalog" });
function pending<T>() { let resolve!: (value: T) => void; let reject!: (error: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
beforeEach(() => { vi.useFakeTimers(); invoke.mockReset(); select.mockReset(); Object.defineProperty(navigator, "language", { value: "en-US", configurable: true }); container = document.createElement("div"); document.body.append(container); root = createRoot(container); });
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.useRealTimers(); });
async function render(props: Partial<Parameters<typeof DictationModelPicker>[0]> = {}) {
  await act(async () => root.render(<DictationModelPicker provider="vercel" baseURL="https://ai-gateway.vercel.sh/v4/ai" model="" keyEpoch={0} configured={true} nativeRuntime disabled={false} onSelect={select} {...props} />));
  await act(async () => { await vi.advanceTimersByTimeAsync(400); });
}
async function click(text: string) { const button = [...container.querySelectorAll("button")].find(button => button.textContent?.includes(text)); expect(button).toBeDefined(); await act(async () => button!.click()); await act(async () => { await vi.advanceTimersByTimeAsync(400); }); }
it("discards a late provider response and displays only returned models", async () => {
  const old = pending<DictationCatalog>(); const next = pending<DictationCatalog>();
  invoke.mockReturnValueOnce(old.promise).mockReturnValueOnce(next.promise);
  await render(); expect(container.textContent).toContain("Loading supported models");
  await render({ provider: "groq", baseURL: "https://api.groq.com/openai/v1" });
  await act(async () => next.resolve(catalog(entry("whisper-large-v3"))));
  await act(async () => old.resolve(catalog(entry("stale-vercel"))));
  expect(container.textContent).not.toContain("stale-vercel");
  await click("whisper-large-v3"); expect(select).toHaveBeenCalledWith("whisper-large-v3");
});
it("reloads after key replacement and ignores a late previous-key result", async () => {
  const old = pending<DictationCatalog>(); invoke.mockReturnValueOnce(old.promise).mockResolvedValue(catalog(entry("new-key-model")));
  await render(); await render({ keyEpoch: 1 });
  await act(async () => old.resolve(catalog(entry("old-key-model"))));
  expect(container.textContent).toContain("new-key-model"); expect(container.textContent).not.toContain("old-key-model");
  expect(invoke).toHaveBeenCalledTimes(2);
});
it("clears catalog on key deletion and endpoint change", async () => {
  invoke.mockResolvedValue(catalog(entry("former-server")));
  await render({ provider: "custom", baseURL: "https://one.test/v1" });
  await render({ provider: "custom", baseURL: "https://one.test/v1", configured: false });
  expect(container.textContent).not.toContain("former-server"); expect(invoke).toHaveBeenCalledTimes(1);
  invoke.mockResolvedValue(catalog()); await render({ provider: "custom", baseURL: "https://two.test/v1" });
  expect(invoke).toHaveBeenLastCalledWith("dictation_list_models", { provider: "custom", baseUrl: "https://two.test/v1" });
});
it("shows errors and empty responses without substituting hardcoded models, and retries", async () => {
  invoke.mockRejectedValueOnce(new Error("fixture unavailable")).mockResolvedValueOnce(catalog());
  await render(); expect(container.querySelector('[role="alert"]')?.textContent).toBe("fixture unavailable");
  expect(container.textContent).not.toContain("gpt-4o-mini-transcribe");
  await click("Refresh models"); expect(container.textContent).toContain("no identifiable file transcription models");
  expect(container.querySelector('[role="alert"]')).toBeNull();
});
it("disables realtime rows and preserves an unavailable saved/manual selection", async () => {
  invoke.mockResolvedValue(catalog(entry("realtime-only", false))); await render({ model: "saved-model" });
  const button = [...container.querySelectorAll("button")].find(button => button.textContent?.includes("realtime-only"));
  expect(button?.disabled).toBe(true); expect(select).not.toHaveBeenCalled();
  expect(container.textContent).toContain("not confirmed for file transcription");
  expect(container.querySelector<HTMLInputElement>("details input")?.value).toBe("saved-model");
});
it("formats only API-reported pricing using Whisp's duration and token rules", () => {
  expect(modelPrice({ ...entry("x"), pricing: { transcription_duration_cost_per_second: "0.0001" } })).toBe("$0.36/hr");
  expect(modelPrice({ ...entry("x"), pricing: { audio_input_token_cost: "0.000001", output: "0.000002" } })).toContain("$1.00 / $2.00");
  expect(modelPrice(entry("x"))).toBe("Price unavailable");
});

it("does not commit a manual ID while typing", async () => {
  invoke.mockResolvedValue(catalog()); await render();
  const input = container.querySelector<HTMLInputElement>("details input")!;
  await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "manual-stt"); input.dispatchEvent(new Event("input", {bubbles:true})); });
  expect(select).not.toHaveBeenCalled(); await click("Use this model"); expect(select).toHaveBeenCalledWith("manual-stt");
});
