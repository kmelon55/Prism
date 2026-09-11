import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { WindowOptions, defaultWindowOptions } from "./WindowOptions";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => native);
let host: HTMLDivElement, root: Root;
beforeEach(() => { vi.spyOn(window, "scrollTo").mockImplementation(() => {}); localStorage.clear(); localStorage.setItem("prism:preferences", JSON.stringify({ language: "en" })); host = document.createElement("div"); document.body.append(host); root = createRoot(host); native.invoke.mockReset().mockResolvedValue(defaultWindowOptions); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); vi.restoreAllMocks(); });
const button = (text: string) => [...host.querySelectorAll("button")].find(button => button.textContent === text)!;
it("previews repeated half sizes, the reverse order and disabled cycling without native calls", async () => {
  await act(async () => root.render(<WindowOptions nativeRuntime={false} />));
  await act(async () => button("Left Half").click()); expect(host.querySelector(".window-preview-tile strong")?.textContent).toBe("1/3");
  await act(async () => button("Left Half").click()); expect(host.querySelector(".window-preview-tile strong")?.textContent).toBe("2/3");
  await act(async () => host.querySelector<HTMLButtonElement>('[role="combobox"]')!.click());
  await act(async () => [...document.querySelectorAll<HTMLButtonElement>('[role="option"]')].find(option => option.textContent === "1/2 → 2/3 → 1/3")!.click());
  await act(async () => button("Left Half").click()); expect(host.querySelector(".window-preview-tile strong")?.textContent).toBe("2/3");
  await act(async () => host.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  await act(async () => button("Left Half").click()); expect(host.querySelector(".window-preview-tile strong")?.textContent).toBe("1/2");
  expect(native.invoke).not.toHaveBeenCalled();
});
it("loads and saves window options without requesting permissions", async () => {
  await act(async () => root.render(<WindowOptions nativeRuntime />));
  await act(async () => host.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  await act(async () => window.dispatchEvent(new Event("pagehide")));
  expect(native.invoke).toHaveBeenCalledWith("set_window_options", { options: { ...defaultWindowOptions, cycle: false } });
  expect(native.invoke.mock.calls.every(([command]) => ["get_window_options", "set_window_options"].includes(command))).toBe(true);
});
