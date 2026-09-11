import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Updates } from "./Updates";
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), listen: vi.fn(), native: vi.fn(), stop: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: mocks.listen }));
vi.mock("./providers/native", () => ({ isTauriRuntime: mocks.native }));
const element = document.createElement("div");
let root: ReturnType<typeof createRoot>;
const available = { currentVersion: "0.1.0", phase: "available", version: "0.2.0", error: null, automaticInstall: false };
beforeEach(() => {
  vi.clearAllMocks(); localStorage.clear(); sessionStorage.clear();
  Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
  mocks.native.mockReturnValue(true);
  mocks.listen.mockResolvedValue(mocks.stop);
  mocks.invoke.mockResolvedValue(available);
  document.body.append(element); root = createRoot(element);
});
afterEach(async () => { await act(async () => root.unmount()); element.remove(); });
it("requires separate installation and restart actions", async () => {
  await act(async () => root.render(<Updates />));
  expect(mocks.invoke).toHaveBeenCalledTimes(1);
  expect(element.textContent).toContain("0.1.0 → 0.2.0");
  mocks.invoke.mockResolvedValue({ ...available, phase: "installed" });
  await act(async () => element.querySelector<HTMLButtonElement>("button")!.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("install_update");
  expect(element.textContent).toContain("Restart Prism");
  expect(mocks.invoke).not.toHaveBeenCalledWith("restart_after_update");
  mocks.invoke.mockResolvedValue(null);
  await act(async () => element.querySelector<HTMLButtonElement>("button")!.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("restart_after_update");
});
it("keeps check failures recoverable without claiming the app is current", async () => {
  mocks.invoke.mockResolvedValue({ ...available, phase: "error", version: null, error: "Network timeout" });
  await act(async () => root.render(<Updates />));
  expect(element.textContent).toContain("Could not update Prism");
  expect(element.textContent).not.toContain("Prism is up to date");
  expect(element.querySelector("button")?.disabled).toBe(false);
  await act(async () => element.querySelector<HTMLButtonElement>("button")!.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("check_for_updates");
});
it("hides browser update UI and does not invoke native APIs", async () => {
  mocks.native.mockReturnValue(false);
  await act(async () => root.render(<Updates />));
  expect(element.textContent).toBe(""); expect(mocks.invoke).not.toHaveBeenCalled();
});
it("prevents installation in a development build", async () => {
  mocks.invoke.mockResolvedValue({ ...available, phase: "development", version: null });
  await act(async () => root.render(<Updates />));
  expect(element.querySelector("button")?.disabled).toBe(true);
});
it("lets users dismiss a notice without installing an update", async () => {
  await act(async () => root.render(<Updates compact />));
  await act(async () => element.querySelectorAll<HTMLButtonElement>("button")[1].click());
  expect(element.textContent).toBe("");
  expect(mocks.invoke).not.toHaveBeenCalledWith("install_update");
});
it("shows a background discovery without requesting a manual check", async () => {
  let notify!: (event: {payload: typeof available}) => void;
  mocks.listen.mockImplementation(async (_name, callback) => { notify = callback; return mocks.stop; });
  mocks.invoke.mockResolvedValue({ ...available, phase: "current", version: null });
  await act(async () => root.render(<Updates compact />));
  expect(element.textContent).toBe("");
  await act(async () => notify({ payload: available }));
  expect(element.textContent).toContain("Download and install");
  expect(mocks.invoke).not.toHaveBeenCalledWith("check_for_updates");
});
it("persists explicit automatic installation without requesting a restart", async () => {
  await act(async () => root.render(<Updates />));
  const toggle = element.querySelector<HTMLButtonElement>('[role="switch"]')!;
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  mocks.invoke.mockResolvedValue({ ...available, automaticInstall: true });
  await act(async () => toggle.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("set_automatic_updates", { enabled: true });
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  expect(mocks.invoke).not.toHaveBeenCalledWith("restart_after_update");
  await act(async () => toggle.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("set_automatic_updates", { enabled: false });
  expect(toggle.getAttribute("aria-checked")).toBe("false");
});
it("keeps automatic installation off when saving the preference fails", async () => {
  await act(async () => root.render(<Updates />));
  mocks.invoke.mockRejectedValue(new Error("disk unavailable"));
  await act(async () => element.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  expect(element.querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("false");
  expect(element.textContent).toContain("Could not save update settings.");
});
it("shows installation failures with a retry and keeps the restart action unavailable", async () => {
  mocks.invoke.mockResolvedValue({ ...available, phase: "error", error: "Invalid signature" });
  await act(async () => root.render(<Updates compact />));
  expect(element.textContent).toContain("Could not update Prism");
  expect(element.textContent).not.toContain("Restart Prism");
  await act(async () => element.querySelector<HTMLButtonElement>("button")!.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("install_update");
});
