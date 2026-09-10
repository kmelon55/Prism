import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { prepareWindowPresentation } from "./windowPresentation";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));

beforeEach(() => {
  vi.useFakeTimers();
  invoke.mockReset().mockResolvedValue(undefined);
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

it("waits for native appearance even when preparing it takes longer than the paint fallback", async () => {
  let prepared!: () => void;
  invoke.mockImplementation((command) => command === "prepare_window_appearance"
    ? new Promise<void>((resolve) => { prepared = resolve; }) : Promise.resolve());
  const cancel = prepareWindowPresentation(true, 44);
  await vi.advanceTimersByTimeAsync(500);
  expect(invoke).not.toHaveBeenCalledWith("window_render_ready");
  prepared();
  await vi.advanceTimersByTimeAsync(150);
  expect(invoke).toHaveBeenCalledWith("prepare_window_appearance", { dark: true, blur: 44 });
  expect(invoke.mock.calls.filter(([command]) => command === "window_render_ready")).toHaveLength(1);
  cancel();
});

it("opens a prepared hidden webview even if it never receives animation frames", async () => {
  vi.spyOn(window, "requestAnimationFrame").mockReturnValue(42);
  const cancel = prepareWindowPresentation(false, 0);
  await vi.advanceTimersByTimeAsync(150);
  expect(invoke).toHaveBeenCalledWith("window_render_ready");
  cancel();
});

it("cancels obsolete appearance work before it can reveal an unmounted window", async () => {
  const cancel = prepareWindowPresentation(true, 44);
  cancel();
  await vi.advanceTimersByTimeAsync(500);
  expect(invoke).not.toHaveBeenCalledWith("window_render_ready");
});
