import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";
import { useDictationPermissions } from "./useDictationPermissions";
import type { DictationStatus } from "./api";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
it("refreshes permission grants and revocations without replacing a live dictation phase", async () => {
  vi.useFakeTimers();
  let granted = false;
  invoke.mockImplementation(async () => ({ phase: "idle", microphone: granted ? "granted" : "denied", accessibility: granted }));
  const node = document.createElement("div"); const root = createRoot(node); const error = vi.fn();
  function Host() {
    const [status, setStatus] = useState<DictationStatus | undefined>({ phase: "recording", microphone: "denied", accessibility: false, message: "", hasTranscript: false });
    useDictationPermissions(true, setStatus, error);
    return <div>{status?.phase}:{String(status?.accessibility)}:{status?.microphone}</div>;
  }
  try {
    await act(async () => root.render(<Host />));
    expect(node.textContent).toBe("recording:false:denied");
    granted = true;
    await act(async () => { window.dispatchEvent(new Event("focus")); });
    expect(node.textContent).toBe("recording:true:granted");
    granted = false;
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    expect(node.textContent).toBe("recording:false:denied");
    expect(invoke.mock.calls.every(([command, args]) => command === "dictation_action" && args.action === "status")).toBe(true);
    await act(async () => root.unmount());
    const count = invoke.mock.calls.length;
    await vi.advanceTimersByTimeAsync(4000); window.dispatchEvent(new Event("focus"));
    expect(invoke.mock.calls.length).toBe(count);
  } finally { vi.useRealTimers(); node.remove(); }
});
