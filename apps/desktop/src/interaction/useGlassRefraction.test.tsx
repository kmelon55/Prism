import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
import { useGlassRefraction } from "./useGlassRefraction";

let container: HTMLDivElement;
let root: Root;
let frames: Map<number, FrameRequestCallback>;
let nextFrame: number;
function Surface({ reduced = false, opening = false }: { reduced?: boolean; opening?: boolean }) {
  return <main ref={useGlassRefraction(reduced, opening)} />;
}
beforeEach(async () => {
  vi.stubGlobal("__TAURI_INTERNALS__", undefined);
  vi.spyOn(document, "hidden", "get").mockReturnValue(false);
  frames = new Map(); nextFrame = 0;
  vi.stubGlobal("requestAnimationFrame", vi.fn((callback: FrameRequestCallback) => {
    frames.set(++nextFrame, callback); return nextFrame;
  }));
  vi.stubGlobal("cancelAnimationFrame", vi.fn((id: number) => frames.delete(id)));
  container = document.createElement("div"); document.body.append(container);
  root = createRoot(container);
  await act(async () => root.render(<Surface />));
  vi.spyOn(container.firstElementChild!, "getBoundingClientRect").mockReturnValue({ left: 100, top: 100, width: 800, height: 500 } as DOMRect);
});
afterEach(async () => {
  await act(async () => root.unmount()); container.remove();
  vi.useRealTimers(); vi.unstubAllGlobals(); vi.restoreAllMocks();
});
function move(x: number, y: number, pointerType = "mouse") {
  const event = new MouseEvent("pointermove", { clientX: x, clientY: y, bubbles: true });
  Object.defineProperty(event, "pointerType", { value: pointerType });
  container.firstElementChild!.dispatchEvent(event);
}
function flush(time = 0) {
  const pending = [...frames.values()]; frames.clear();
  pending.forEach(callback => callback(time));
}
it("coalesces pointer events into one frame and does no work at rest", () => {
  move(200, 200); move(500, 350); move(window.innerWidth, window.innerHeight);
  expect(frames.size).toBe(1);
  flush();
  const shell = container.firstElementChild as HTMLElement;
  expect(shell.style.getPropertyValue("--glass-x")).toBe("88.00%");
  expect(shell.style.getPropertyValue("--glass-y")).toBe("72.00%");
  expect(frames.size).toBe(0);
});
it("preserves lighting across pointer exit and window blur and tracks outside the shell", () => {
  move(300, 300);
  container.firstElementChild!.dispatchEvent(new Event("pointerleave"));
  expect(frames.size).toBe(1);
  flush();
  const shell = container.firstElementChild as HTMLElement;
  const before = shell.style.cssText;
  window.dispatchEvent(new Event("blur"));
  expect(shell.style.cssText).toBe(before);
  document.dispatchEvent(new MouseEvent("pointermove", { clientX: 0, clientY: 0 }));
  flush();
  expect(shell.style.getPropertyValue("--glass-x")).toBe("12.00%");
  expect(shell.style.getPropertyValue("--glass-y")).toBe("8.00%");
});
it("ignores touch and freezes the last lighting when reduced motion is enabled", async () => {
  move(300, 300, "touch"); expect(frames.size).toBe(0);
  move(300, 300); flush();
  const before = (container.firstElementChild as HTMLElement).style.cssText;
  move(500, 400);
  await act(async () => root.render(<Surface reduced />));
  expect(frames.size).toBe(0);
  expect((container.firstElementChild as HTMLElement).style.cssText).toBe(before);
  move(500, 400); expect(frames.size).toBe(0);
});
it("uses screen-wide native lighting after focus leaves and cancels polling on unmount", async () => {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
  vi.stubGlobal("__TAURI_INTERNALS__", {});
  vi.mocked(invoke).mockResolvedValue([.7, .3]);
  await act(async () => root.render(<Surface key="native" />));
  flush();
  expect((container.firstElementChild as HTMLElement).style.getPropertyValue("--glass-x")).toBe("70.00%");
  window.dispatchEvent(new Event("blur"));
  vi.mocked(invoke).mockResolvedValue([.2, .6]);
  await act(async () => vi.advanceTimersByTimeAsync(34));
  flush();
  expect((container.firstElementChild as HTMLElement).style.getPropertyValue("--glass-x")).toBe("20.00%");
  await act(async () => root.render(<Surface key="native" reduced />));
  const calls = vi.mocked(invoke).mock.calls.length;
  await vi.advanceTimersByTimeAsync(500);
  expect(vi.mocked(invoke).mock.calls.length).toBe(calls);
});

it("starts at six oclock, moves clockwise and settles on the pointer in 1.5 seconds", async () => {
  await act(async () => root.render(<Surface key="arrival" opening />));
  const shell = container.firstElementChild as HTMLElement;
  expect(shell.style.getPropertyValue("--glass-angle")).toBe("135.00deg");
  expect(shell.style.getPropertyValue("--glass-y")).toBe("72.00%");
  move(window.innerWidth * .75, window.innerHeight * .25);
  flush(100);
  const start = parseFloat(shell.style.getPropertyValue("--glass-angle"));
  flush(850);
  expect(parseFloat(shell.style.getPropertyValue("--glass-angle"))).toBeGreaterThan(start);
  expect(frames.size).toBe(1);
  flush(1600);
  expect(parseFloat(shell.style.getPropertyValue("--glass-x"))).toBeCloseTo(75, 0);
  expect(parseFloat(shell.style.getPropertyValue("--glass-y"))).toBeCloseTo(25, 0);
  expect(frames.size).toBe(0);
  move(0, 0); flush(1700);
  expect(shell.style.getPropertyValue("--glass-x")).toBe("12.00%");
});
it("cancels an in-flight sweep when disabled and respects reduced motion", async () => {
  await act(async () => root.render(<Surface key="arrival" opening />));
  flush(0); flush(500);
  await act(async () => root.render(<Surface key="arrival" opening={false} />));
  flush(600); expect(frames.size).toBe(0);
  await act(async () => root.render(<Surface key="reduced-arrival" opening reduced />));
  expect(frames.size).toBe(0);
});
it("replays after native hide/show, but not ordinary focus changes", async () => {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
  vi.stubGlobal("__TAURI_INTERNALS__", {});
  vi.mocked(invoke).mockResolvedValue([.7, .3]);
  await act(async () => root.render(<Surface key="native-arrival" opening />));
  const shell = container.firstElementChild as HTMLElement;
  flush(0); flush(1500);
  const settled = shell.style.cssText;
  window.dispatchEvent(new Event("blur")); window.dispatchEvent(new Event("focus"));
  await act(async () => vi.advanceTimersByTimeAsync(34));
  expect(shell.style.cssText).toBe(settled);
  vi.mocked(invoke).mockResolvedValue(null);
  await act(async () => vi.advanceTimersByTimeAsync(34));
  expect(frames.size).toBe(0);
  vi.mocked(invoke).mockResolvedValue([.2, .6]);
  await act(async () => vi.advanceTimersByTimeAsync(34));
  expect(shell.style.getPropertyValue("--glass-angle")).toBe("135.00deg");
  expect(frames.size).toBe(1);
});
it("keeps a moving destination clockwise instead of snapping backward at completion", async () => {
  await act(async () => root.render(<Surface key="moving-arrival" opening />));
  const shell = container.firstElementChild as HTMLElement;
  move(window.innerWidth * .75, window.innerHeight * .25);
  flush(0); flush(900);
  const before = parseFloat(shell.style.getPropertyValue("--glass-angle"));
  move(window.innerWidth * .25, window.innerHeight * .5);
  flush(1200);
  const during = parseFloat(shell.style.getPropertyValue("--glass-angle"));
  expect(during).toBeGreaterThanOrEqual(before);
  flush(1500);
  expect(parseFloat(shell.style.getPropertyValue("--glass-angle"))).toBeGreaterThanOrEqual(during);
  expect(parseFloat(shell.style.getPropertyValue("--glass-x"))).toBeCloseTo(25, 0);
  expect(frames.size).toBe(0);
});
