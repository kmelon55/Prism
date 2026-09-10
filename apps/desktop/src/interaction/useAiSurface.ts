import { useCallback, useEffect, useRef, useState } from "react";
import { useReducedMotion } from "motion/react";

// Keep the departing chat mounted for its short exit; native collapse starts after it clears.
export function useAiSurface(preferReducedMotion: boolean) {
  const systemReducedMotion = useReducedMotion();
  const reducedMotion = preferReducedMotion || Boolean(systemReducedMotion);
  const [open, setOpen] = useState(false);
  const [phase, setPhase] = useState("closed");
  const target = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const clear = () => { if (timer.current !== null) clearTimeout(timer.current); timer.current = null; };
  useEffect(() => () => clear(), []);
  useEffect(() => {
    if (reducedMotion) { clear(); setOpen(target.current); setPhase(target.current ? "open" : "closed"); }
  }, [reducedMotion]);
  const change = useCallback((next: boolean) => {
    if (target.current === next) return;
    target.current = next; clear();
    if (reducedMotion) { setOpen(next); setPhase(next ? "open" : "closed"); return; }
    if (next) {
      setOpen(true); setPhase("opening");
      timer.current = setTimeout(() => { setPhase("open"); timer.current = null; }, 500);
    } else {
      setPhase("closing");
      timer.current = setTimeout(() => {
        setOpen(false); setPhase("returning");
        timer.current = setTimeout(() => { setPhase("closed"); timer.current = null; }, 360);
      }, 120);
    }
  }, [reducedMotion]);
  return { open, phase, reducedMotion, change };
}
