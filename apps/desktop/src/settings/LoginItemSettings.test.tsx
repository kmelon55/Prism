import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { LoginItemSettings } from "./LoginItemSettings";
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), native: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("../providers/native", () => ({ isTauriRuntime: mocks.native }));
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  vi.resetAllMocks(); localStorage.clear();
  Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
  mocks.native.mockReturnValue(true); mocks.invoke.mockResolvedValue("notRegistered");
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
});
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });
async function mount() { await act(async () => root.render(<LoginItemSettings />)); }
function toggle() { return host.querySelector<HTMLButtonElement>('[role="switch"]')!; }
it("reads native registration without enabling it and only changes it on a user action", async () => {
  await mount(); expect(toggle().getAttribute("aria-checked")).toBe("false");
  expect(mocks.invoke).toHaveBeenCalledExactlyOnceWith("get_login_item_status");
  mocks.invoke.mockResolvedValue("enabled");
  await act(async () => toggle().click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("set_login_item_enabled", { enabled: true });
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  mocks.invoke.mockResolvedValue("notRegistered");
  await act(async () => toggle().click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("set_login_item_enabled", { enabled: false });
  expect(toggle().getAttribute("aria-checked")).toBe("false");
});
it("shows pending approval as inactive, opens System Settings, and refreshes after returning", async () => {
  mocks.invoke.mockResolvedValue("requiresApproval"); await mount();
  expect(toggle().getAttribute("aria-checked")).toBe("false");
  expect(host.textContent).toContain("Allow Prism in System Settings");
  await act(async () => [...host.querySelectorAll('button')].find(b => b.textContent === "Open Login Items")!.click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("open_login_item_settings");
  mocks.invoke.mockResolvedValue("enabled");
  await act(async () => window.dispatchEvent(new Event("focus")));
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  expect(host.textContent).not.toContain("Open Login Items");
});
it("can cancel a pending registration", async () => {
  mocks.invoke.mockResolvedValue("requiresApproval"); await mount();
  mocks.invoke.mockResolvedValue("notRegistered");
  await act(async () => toggle().click());
  expect(mocks.invoke).toHaveBeenLastCalledWith("set_login_item_enabled", { enabled: false });
});
it("rereads actual status after a failed mutation and permits retry", async () => {
  await mount();
  mocks.invoke.mockRejectedValueOnce(new Error("denied")).mockResolvedValue("notRegistered");
  await act(async () => toggle().click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Could not change");
  expect(toggle().getAttribute("aria-checked")).toBe("false"); expect(toggle().disabled).toBe(false);
});
it("offers recovery when status cannot be read", async () => {
  mocks.invoke.mockRejectedValue(new Error("unavailable")); await mount();
  expect(toggle().disabled).toBe(true);
  mocks.invoke.mockResolvedValue("enabled");
  await act(async () => [...host.querySelectorAll('button')].find(b => b.textContent === "Refresh")!.click());
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  expect(host.querySelector('[role="alert"]')).toBeNull();
});
it("does not register development or uninstalled copies", async () => {
  mocks.invoke.mockResolvedValue("unsupported"); await mount();
  expect(toggle().disabled).toBe(true); expect(host.textContent).toContain("Applications");
});
it("hides native controls in browser previews", async () => {
  mocks.native.mockReturnValue(false); await mount();
  expect(host.textContent).toBe(""); expect(mocks.invoke).not.toHaveBeenCalled();
});
it("ignores an older focus read that finishes after a mutation", async () => {
  await mount();
  let resolve!: (value: string) => void;
  mocks.invoke.mockReturnValueOnce(new Promise<string>(r => { resolve = r; }));
  await act(async () => window.dispatchEvent(new Event("focus")));
  mocks.invoke.mockResolvedValue("enabled");
  await act(async () => toggle().click());
  await act(async () => resolve("notRegistered"));
  expect(toggle().getAttribute("aria-checked")).toBe("true");
});
it("prevents repeated changes while registration is pending", async () => {
  await mount(); let resolve!: (value: string) => void;
  mocks.invoke.mockReturnValueOnce(new Promise<string>(r => { resolve = r; }));
  await act(async () => { toggle().click(); toggle().click(); });
  expect(toggle().disabled).toBe(true);
  expect(mocks.invoke.mock.calls.filter(([name]) => name === "set_login_item_enabled")).toHaveLength(1);
  await act(async () => resolve("requiresApproval"));
  expect(toggle().disabled).toBe(false); expect(toggle().getAttribute("aria-checked")).toBe("false");
});
