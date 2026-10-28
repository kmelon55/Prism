import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { LocalModelPicker, type LocalModels } from "./LocalModelPicker";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
let root: Root; let container: HTMLDivElement; let catalog: LocalModels;
const select = vi.fn();
function pending<T>() { let resolve!: (value: T) => void; let reject!: (error: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
beforeEach(() => {
  vi.useFakeTimers(); localStorage.clear(); Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
  select.mockReset().mockResolvedValue(undefined);
  catalog = { models: [{ id: "large-v3", name: "Whisper Large v3", description: "Supports Korean", bytes: 3095033483, path: null }], whisperPath: "/opt/homebrew/bin/whisper-cli", canInstallEngine: true, installingEngine: false, download: null };
  invoke.mockReset().mockImplementation(async command => {
    if (command === "dictation_local_models") return catalog;
    if (command === "dictation_download_model") { catalog = { ...catalog, models: [{ ...catalog.models[0], path: "/models/ggml-large-v3.bin" }] }; return catalog.models[0].path; }
    if (command === "dictation_install_whisper") { catalog = { ...catalog, whisperPath: "/opt/homebrew/bin/whisper-cli" }; return catalog.whisperPath; }
  });
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.useRealTimers(); });
async function render(props: Partial<Parameters<typeof LocalModelPicker>[0]> = {}) { await act(async () => root.render(<LocalModelPicker modelPath="" whisperPath="/old/whisper-cli" nativeRuntime disabled={false} onSelect={select} {...props} />)); }
async function click(text: string) { const button = [...container.querySelectorAll("button")].find(button => button.textContent?.includes(text)); expect(button).toBeDefined(); await act(async () => button!.click()); }
it("shows sizes without downloading and activates only after a successful download", async () => {
  await render(); expect(container.textContent).toContain("3.10 GB");
  expect(invoke.mock.calls.every(([command]) => command === "dictation_local_models")).toBe(true);
  await click("Whisper Large v3");
  expect(invoke).toHaveBeenCalledWith("dictation_download_model", { modelId: "large-v3" });
  expect(select).toHaveBeenCalledWith(expect.objectContaining({ id: "large-v3" }), "/models/ggml-large-v3.bin", "/opt/homebrew/bin/whisper-cli");
});
it("keeps the previous selection on download failure and allows retry", async () => {
  const original = invoke.getMockImplementation()!;
  invoke.mockImplementation(async (command, args) => { if (command === "dictation_download_model") throw Error("disk full"); return original(command, args); });
  await render(); await click("Whisper Large v3");
  expect(select).not.toHaveBeenCalled(); expect(container.querySelector('[role="alert"]')?.textContent).toContain("disk full");
  expect(container.querySelector<HTMLButtonElement>(".dictation-model")!.disabled).toBe(false);
  invoke.mockImplementation(original); await click("Whisper Large v3"); expect(select).toHaveBeenCalledTimes(1);
});
it("requires an explicit engine install and never activates a model without its engine", async () => {
  catalog.whisperPath = null;
  await render(); await click("Whisper Large v3");
  expect(select).not.toHaveBeenCalled(); expect(invoke.mock.calls.some(([command]) => command === "dictation_install_whisper")).toBe(false);
  expect(container.textContent).toContain("Model downloaded. Install the speech engine");
  await click("Install speech engine"); await click("Whisper Large v3"); expect(select).toHaveBeenCalledTimes(1);
});
it("restores an ongoing download and can cancel it after reopening", async () => {
  catalog.download = { modelId: "large-v3", downloaded: 1000000000, total: 3095033483 };
  await render(); expect(container.querySelector("progress")?.value).toBe(1000000000);
  expect(container.querySelector<HTMLButtonElement>(".dictation-model")!.disabled).toBe(true);
  await click("Cancel download"); expect(invoke).toHaveBeenCalledWith("dictation_cancel_model_download", { modelId: "large-v3" });
});
it("does not apply a completed download after leaving the picker", async () => {
  const download = pending<string>(); const original = invoke.getMockImplementation()!;
  invoke.mockImplementation((command, args) => command === "dictation_download_model" ? download.promise : original(command, args));
  await render(); await click("Whisper Large v3");
  await act(async () => root.render(null));
  await act(async () => download.resolve("/models/model.bin")); expect(select).not.toHaveBeenCalled();
});
it("does not apply a completed download if recording starts meanwhile", async () => {
  const download = pending<string>(); const original = invoke.getMockImplementation()!;
  invoke.mockImplementation((command, args) => command === "dictation_download_model" ? download.promise : original(command, args));
  await render(); await click("Whisper Large v3"); await render({ disabled: true });
  await act(async () => download.resolve("/models/model.bin")); expect(select).not.toHaveBeenCalled();
});
it("keeps a save failure visible and reuses the verified file on retry", async () => {
  select.mockRejectedValueOnce(Error("Settings could not be saved."));
  await render(); await click("Whisper Large v3");
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Settings could not be saved.");
  expect(container.textContent).toContain("Use model"); await click("Whisper Large v3"); expect(select).toHaveBeenCalledTimes(2);
});
it("does not invoke native commands in a browser", async () => { await render({ nativeRuntime: false }); expect(invoke).not.toHaveBeenCalled(); });
it("preserves a manual model selection made during a download", async () => {
  const download = pending<string>(); const original = invoke.getMockImplementation()!;
  invoke.mockImplementation((command, args) => command === "dictation_download_model" ? download.promise : original(command, args));
  await render(); await click("Whisper Large v3"); await render({ modelPath: "/custom/model.bin" });
  await act(async () => download.resolve("/models/model.bin")); expect(select).not.toHaveBeenCalled();
});
it("preserves an executable changed during a download", async () => {
  const download = pending<string>(); const original = invoke.getMockImplementation()!;
  invoke.mockImplementation((command, args) => command === "dictation_download_model" ? download.promise : original(command, args));
  await render(); await click("Whisper Large v3"); await render({ whisperPath: "/custom/whisper-cli" });
  await act(async () => download.resolve("/models/model.bin")); expect(select).not.toHaveBeenCalled();
});
