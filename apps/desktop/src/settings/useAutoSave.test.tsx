import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useAutoSave } from "./useAutoSave";

let root: Root;
let container: HTMLDivElement;
let autoSave: ReturnType<typeof useAutoSave<string>>;
const save = vi.fn<(value: string) => Promise<unknown>>();
function Harness() { autoSave = useAutoSave(save); return <span>{autoSave.status}</span>; }
beforeEach(async () => {
  vi.useFakeTimers(); save.mockReset().mockResolvedValue(undefined);
  container = document.createElement("div"); root = createRoot(container);
  await act(async () => root.render(<StrictMode><Harness /></StrictMode>));
});
afterEach(async () => { await act(async () => root.unmount()); vi.useRealTimers(); });
it("does not write on mount and combines rapid typing into the latest value", async () => {
  expect(save).not.toHaveBeenCalled();
  await act(async () => { autoSave.schedule("first"); await vi.advanceTimersByTimeAsync(200); autoSave.schedule("latest"); await vi.advanceTimersByTimeAsync(399); });
  expect(save).not.toHaveBeenCalled();
  await act(async () => { await vi.advanceTimersByTimeAsync(1); });
  expect(save).toHaveBeenCalledExactlyOnceWith("latest"); expect(autoSave.status).toBe("saved");
});
it("serializes changes made while a write is pending", async () => {
  let finish!: () => void;
  save.mockImplementationOnce(() => new Promise<void>(resolve => { finish = resolve; }));
  await act(async () => autoSave.schedule("first", 0));
  await act(async () => { autoSave.schedule("second", 0); autoSave.schedule("latest", 0); });
  expect(save).toHaveBeenCalledTimes(1);
  await act(async () => finish());
  expect(save.mock.calls).toEqual([["first"], ["latest"]]); expect(autoSave.status).toBe("saved");
});
it("flushes pending input when the section unmounts", async () => {
  await act(async () => autoSave.schedule("last edit"));
  await act(async () => root.render(null));
  expect(save).toHaveBeenCalledExactlyOnceWith("last edit");
});
it("reports failures without looping and lets the user retry the latest input", async () => {
  save.mockRejectedValueOnce(new Error("disk full"));
  await act(async () => autoSave.schedule("draft", 0));
  expect(autoSave.status).toBe("error"); expect(autoSave.error).toBe("disk full");
  await act(async () => { await vi.advanceTimersByTimeAsync(5000); });
  expect(save).toHaveBeenCalledTimes(1);
  await act(async () => autoSave.retry());
  expect(save).toHaveBeenCalledTimes(2); expect(autoSave.status).toBe("saved"); expect(autoSave.error).toBe("");
});
