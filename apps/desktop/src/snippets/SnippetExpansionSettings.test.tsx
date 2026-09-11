import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { SnippetExpansionSettings, type SnippetExpansionStatus } from "./SnippetExpansionSettings";

const mocks = vi.hoisted(() => ({ native: true, invoke: vi.fn(), listen: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: mocks.listen }));
vi.mock("../providers/native", () => ({ isTauriRuntime: () => mocks.native }));
let root: Root; let container: HTMLDivElement; let state: SnippetExpansionStatus;
beforeEach(() => {
  vi.clearAllMocks(); mocks.native = true;
  localStorage.setItem("prism:preferences", JSON.stringify({ language: "en", snippetExpansionEnabled: true }));
  state = { enabled: false, supported: true, active: false, accessibilityGranted: false, inputMonitoringGranted: false, excludedApps: [], registeredCount: 1, error: null };
  mocks.listen.mockResolvedValue(() => undefined);
  mocks.invoke.mockImplementation(async (command: string, args?: { enabled: boolean; excludedApps: string[] }) => {
    if (command === "snippet_expansion_configure") state = { ...state, ...args };
    return { ...state };
  });
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount() { await act(async () => root.render(<StrictMode><SnippetExpansionSettings /></StrictMode>)); }
async function click(label: string) { const button = [...container.querySelectorAll("button")].find((button) => button.textContent === label || button.getAttribute("aria-label") === label)!; await act(async () => button.click()); }
it("uses default-off native state and never requests permission on mount", async () => {
  await mount();
  expect(container.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("false");
  expect(mocks.invoke.mock.calls.every(([command]) => command === "snippet_expansion_status")).toBe(true);
  expect(container.textContent).toContain("Needs access");
  await click("Enable snippet expansion");
  expect(mocks.invoke).toHaveBeenCalledWith("snippet_expansion_configure", { enabled: true, excludedApps: [] });
  expect(container.textContent).toContain("Paused");
  await click("Review permissions");
  expect(mocks.invoke).toHaveBeenCalledWith("snippet_expansion_request_permissions");
});
it("preserves an exclusion draft across permission refresh and saves automatically", async () => {
  await mount(); const input = container.querySelector("textarea")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, "com.example.editor\ncom.example.editor\n");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  state = { ...state, accessibilityGranted: true, inputMonitoringGranted: true };
  await click("Refresh status"); expect(input.value).toContain("com.example.editor");
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 450)); });
  expect(mocks.invoke).toHaveBeenCalledWith("snippet_expansion_configure", { enabled: false, excludedApps: ["com.example.editor"] });
});
it("fails closed after a configure failure without displaying enabled state", async () => {
  await mount(); mocks.invoke.mockRejectedValueOnce(new Error("Disk full"));
  await click("Enable snippet expansion");
  expect(container.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("false");
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
});
it("disables browser controls and makes no native calls", async () => {
  mocks.native = false; await mount();
  expect(mocks.invoke).not.toHaveBeenCalled(); expect(mocks.listen).not.toHaveBeenCalled();
  expect(container.querySelector<HTMLButtonElement>('[role="switch"]')!.disabled).toBe(true);
  expect(container.textContent).toContain("macOS desktop app");
});
it("rechecks revoked permissions on focus and leaves the preference visible", async () => {
  state = { ...state, enabled: true, active: true, accessibilityGranted: true, inputMonitoringGranted: true }; await mount();
  state = { ...state, active: false, inputMonitoringGranted: false };
  await act(async () => window.dispatchEvent(new Event("focus")));
  expect(container.textContent).toContain("Paused"); expect(container.textContent).toContain("Input Monitoring: Needs access");
  expect(container.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("true");
});

it("shows an unavailable build without offering activation or permission prompts", async () => {
  state = { ...state, supported: false }; await mount();
  expect(container.textContent).toContain("Automatic expansion is unavailable in this build");
  expect(container.querySelector('[role="switch"]')).toBeNull();
  expect(container.querySelector("button")).toBeNull();
  expect(mocks.invoke.mock.calls.every(([command]) => command === "snippet_expansion_status")).toBe(true);
});
