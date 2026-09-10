import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { useShortcutCaptureLease } from "./shortcutCapture";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
let root: Root; let node: HTMLDivElement;
beforeEach(() => { invoke.mockReset().mockResolvedValue(undefined); node = document.createElement("div"); document.body.append(node); root = createRoot(node); });
afterEach(async () => { await act(async () => root.unmount()); node.remove(); });
function Host() {
  const [active, setActive] = useState(true);
  const lease = useShortcutCaptureLease(true, active, "settings", () => setActive(false));
  return <div data-active={active} data-ready={lease.ready}>{lease.error}</div>;
}
it("suppresses native double taps only while recording, and releases on window blur", async () => {
  await act(async () => root.render(<Host />));
  expect(invoke).toHaveBeenCalledWith("set_shortcut_capture", { owner: "settings", active: true });
  expect(node.firstElementChild?.getAttribute("data-ready")).toBe("true");
  await act(async () => { window.dispatchEvent(new Event("blur")); });
  expect(node.firstElementChild?.getAttribute("data-active")).toBe("false");
  expect(invoke).toHaveBeenLastCalledWith("set_shortcut_capture", { owner: "settings", active: false });
});
it("cancels capture and keeps a native capture failure visible", async () => {
  invoke.mockImplementation(async (_command, { active }) => { if (active) throw "Capture unavailable"; });
  await act(async () => root.render(<Host />));
  expect(node.firstElementChild?.getAttribute("data-active")).toBe("false");
  expect(node.textContent).toBe("Capture unavailable");
  expect(invoke).toHaveBeenLastCalledWith("set_shortcut_capture", { owner: "settings", active: false });
});
