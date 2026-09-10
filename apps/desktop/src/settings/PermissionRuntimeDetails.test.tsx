import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";
import { PermissionRuntimeDetails } from "./PermissionRuntimeDetails";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
it("shows the actual bare executable instead of directing development users to another Prism.app", async () => {
  localStorage.clear(); Object.defineProperty(navigator, "language", { configurable: true, value: "en-US" });
  const runtime = { executablePath: "/fixture/target/debug/prism-desktop", permissionTarget: "/fixture/target/debug/prism-desktop", bundled: false, adHoc: true, identifier: "fixture", codeHash: "abcd", pid: 1 };
  invoke.mockResolvedValue(runtime);
  const node = document.createElement("div"); document.body.append(node); const root = createRoot(node);
  await act(async () => root.render(<PermissionRuntimeDetails nativeRuntime granted={false} />));
  expect(node.textContent).toContain(runtime.permissionTarget);
  expect(node.textContent).toContain("Its permissions can differ from the installed Prism.app");
  expect(node.textContent).toContain("native rebuild");
  await act(async () => node.querySelector("button")!.click());
  expect(invoke).toHaveBeenLastCalledWith("reveal_permission_target");
  await act(async () => root.unmount()); node.remove();
});
