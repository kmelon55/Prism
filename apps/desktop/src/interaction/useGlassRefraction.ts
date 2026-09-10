import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";

export const OPENING_LIGHT_DURATION = 1500;
const direction = (point: number[]) => Math.atan2(point[1] - .5, point[0] - .5) * 180 / Math.PI + 90;
const clockwise = (angle: number) => ((angle % 360) + 360) % 360;

/** One arrival sweep, followed by direct screen-wide pointer lighting. */
export function useGlassRefraction(reducedMotion: boolean, openingAnimation = false) {
  const ref = useRef<HTMLElement>(null);
  const opening = useRef(openingAnimation);
  opening.current = openingAnimation;
  useEffect(() => {
    const shell = ref.current;
    if (!shell || reducedMotion) return;
    let disposed = false;
    let frame = 0;
    let timer = 0;
    let pending = false;
    let visible = false;
    let generation = 0;
    let angle = Number.parseFloat(shell.style.getPropertyValue("--glass-angle"));
    angle = Number.isFinite(angle) ? angle + 45 : -33;
    let point = [.32, .22];
    let sweep: { started: number | null; end: number } | null = null;
    const native = Boolean(window.__TAURI_INTERNALS__);
    const paint = (position: number[], degrees: number) => {
      angle = degrees;
      shell.style.setProperty("--glass-x", `${(position[0] * 100).toFixed(2)}%`);
      shell.style.setProperty("--glass-y", `${(position[1] * 100).toFixed(2)}%`);
      // The white core sits at 12.5% (45 degrees) in the conic gradient.
      shell.style.setProperty("--glass-angle", `${(degrees - 45).toFixed(2)}deg`);
    };
    const tick = (now: number) => {
      frame = 0;
      if (disposed) return;
      if (sweep && opening.current) {
        sweep.started ??= now;
        const progress = Math.min(1, Math.max(0, (now - sweep.started) / OPENING_LIGHT_DURATION));
        const eased = 1 - Math.pow(1 - progress, 3);
        const degrees = Math.max(angle, 180 + (sweep.end - 180) * eased);
        const radius = .22 + (Math.hypot(point[0] - .5, point[1] - .5) - .22) * eased;
        const radians = degrees * Math.PI / 180;
        paint([.5 + Math.sin(radians) * radius, .5 - Math.cos(radians) * radius], degrees);
        if (progress < 1) { frame = requestAnimationFrame(tick); return; }
      }
      sweep = null;
      const degrees = angle + clockwise(direction(point) - angle + 180) - 180;
      paint(point, degrees);
    };
    const schedule = () => { if (!frame) frame = requestAnimationFrame(tick); };
    const arrive = () => {
      if (visible) return;
      visible = true;
      if (opening.current && !shell.classList.contains("ai-expanded")) {
        let travel = clockwise(direction(point) - 180);
        if (travel < 30) travel += 360;
        sweep = { started: null, end: 180 + travel };
        paint([.5, .72], 180);
        schedule();
      }
    };
    const hide = () => {
      visible = false;
      sweep = null;
      generation++;
      cancelAnimationFrame(frame);
      frame = 0;
    };
    const light = (x: number, y: number) => {
      if (disposed || !Number.isFinite(x) || !Number.isFinite(y)) return;
      const next = [Math.max(.12, Math.min(.88, x)), Math.max(.08, Math.min(.72, y))];
      const changed = next[0] !== point[0] || next[1] !== point[1];
      point = next;
      if (sweep) {
        // Follow a moving destination without reversing the clockwise sweep.
        sweep.end += clockwise(direction(point) - sweep.end + 180) - 180;
        if (sweep.end < angle) sweep.end += 360;
      }
      if (changed) schedule();
    };
    const move = (event: PointerEvent) => {
      if (event.pointerType !== "touch") light(event.clientX / window.innerWidth, event.clientY / window.innerHeight);
    };
    const poll = async () => {
      if (disposed || document.hidden || pending) return;
      pending = true;
      const current = generation;
      try {
        const position = await invoke<[number, number] | null>("get_glass_lighting");
        if (disposed || current !== generation) return;
        if (position) { light(position[0], position[1]); arrive(); }
        else hide(); // The native command returns null while its window is hidden.
      } catch { /* Keep the last reflection when the native window is unavailable. */ }
      finally { pending = false; }
    };
    const visibility = () => {
      window.clearInterval(timer);
      if (document.hidden) { hide(); return; }
      if (native) {
        void poll();
        timer = window.setInterval(() => void poll(), 1000 / 30);
      } else arrive();
    };
    visibility();
    if (!native) document.addEventListener("pointermove", move, { passive: true });
    document.addEventListener("visibilitychange", visibility);
    return () => {
      disposed = true;
      cancelAnimationFrame(frame);
      window.clearInterval(timer);
      document.removeEventListener("pointermove", move);
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [reducedMotion]);
  return ref;
}
