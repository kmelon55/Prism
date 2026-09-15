import { afterEach, expect, it, vi } from "vitest";
import { afterClipboardRender } from "./presentation";

afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

it("reveals a committed hidden view once even when animation frames are suspended", async () => {
  vi.useFakeTimers();
  vi.spyOn(window, "requestAnimationFrame").mockReturnValue(9);
  const reveal = vi.fn();
  const cancel = afterClipboardRender(reveal);
  expect(reveal).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(80);
  expect(reveal).toHaveBeenCalledTimes(1);
  cancel();
});

it("cancels an obsolete view before its fallback can reveal the window", async () => {
  vi.useFakeTimers();
  vi.spyOn(window, "requestAnimationFrame").mockReturnValue(9);
  const reveal = vi.fn();
  afterClipboardRender(reveal)();
  await vi.advanceTimersByTimeAsync(100);
  expect(reveal).not.toHaveBeenCalled();
});
