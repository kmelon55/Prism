import { Children, createContext, useContext, useEffect, useRef, useState, type ComponentProps, type ReactNode } from "react";
import { AnimatePresence, motion, useIsPresent, useReducedMotion } from "motion/react";

const MotionPreference = createContext(false);
const ease = [0.22, 1, 0.36, 1] as const;
export function InterfaceMotion({ reducedMotion, children }: { reducedMotion: boolean; children: ReactNode }) {
  return <MotionPreference.Provider value={reducedMotion}>{children}</MotionPreference.Provider>;
}
function useQuietMotion() {
  const preferred = useContext(MotionPreference);
  const system = useReducedMotion();
  return preferred || system === true;
}
function CollapseBody({ children }: { children: ReactNode }) {
  const present = useIsPresent();
  const quiet = useQuietMotion();
  return <motion.div className="settings-collapse" inert={!present} aria-hidden={!present || undefined}
    initial={{ height: 0, opacity: 0 }} animate={{ height: "auto", opacity: 1 }} exit={{ height: 0, opacity: 0 }}
    transition={{ duration: quiet ? 0 : .24, ease }}>
    <div className="settings-collapse-content">{children}</div>
  </motion.div>;
}
export function AnimatedCollapse({ open, children, reducedMotion = false }: { open: boolean; children: ReactNode; reducedMotion?: boolean }) {
  const preferred = useQuietMotion();
  const quiet = preferred || reducedMotion;
  if (quiet) return open ? <>{children}</> : null;
  return <AnimatePresence initial={false}>{open && <CollapseBody>{children}</CollapseBody>}</AnimatePresence>;
}
export function AnimatedPanel({ children, ...props }: ComponentProps<typeof motion.section>) {
  const present = useIsPresent();
  const quiet = useQuietMotion();
  return <motion.section {...props} inert={!present} aria-hidden={!present || undefined}
    initial={quiet ? false : { opacity: 0, y: -5, scale: .985 }} animate={{ opacity: 1, y: 0, scale: 1 }}
    exit={{ opacity: 0, y: -3, scale: .99 }} transition={{ duration: quiet ? 0 : present ? .2 : .14, ease }}>
    {children}
  </motion.section>;
}

/** Keep native details semantics; defer closing until its measured height settles. */
export function AnimatedDetails({ children, className, ...props }: ComponentProps<"details">) {
  const root = useRef<HTMLDetailsElement>(null);
  const animation = useRef<Animation | null>(null);
  const targetOpen = useRef<boolean | null>(null);
  const [closing, setClosing] = useState(false);
  const quiet = useQuietMotion();
  const [summary, ...content] = Children.toArray(children);
  useEffect(() => () => animation.current?.cancel(), []);
  useEffect(() => {
    if (!quiet || !animation.current || !root.current) return;
    animation.current.cancel(); animation.current = null;
    root.current.open = targetOpen.current ?? root.current.open;
    targetOpen.current = null; root.current.style.overflow = ""; setClosing(false);
  }, [quiet]);
  return <details {...props} ref={root} className={`animated-details ${className ?? ""}`} data-closing={closing || undefined}
    onClick={event => {
      props.onClick?.(event);
      const element = root.current;
      const clicked = event.target instanceof Element ? event.target.closest("summary") : null;
      if (event.defaultPrevented || !element || !clicked || clicked !== element.querySelector(":scope > summary")) return;
      if (event.target instanceof Element && event.target.closest("a, button, input, select")) return;
      if (quiet || typeof element.animate !== "function") return;
      event.preventDefault();
      const open = !(targetOpen.current ?? element.open);
      const from = element.getBoundingClientRect().height;
      animation.current?.cancel();
      element.open = true;
      targetOpen.current = open; setClosing(!open);
      const height = open ? element.getBoundingClientRect().height : clicked.getBoundingClientRect().height;
      element.style.overflow = "hidden";
      const next = element.animate([{ height: `${from}px` }, { height: `${height}px` }], { duration: 240, easing: "cubic-bezier(.22, 1, .36, 1)" });
      animation.current = next;
      next.onfinish = () => {
        if (animation.current !== next) return;
        element.open = open; element.style.overflow = "";
        animation.current = null; targetOpen.current = null; setClosing(false);
      };
    }}>
    {summary}
    <div className="animated-details-content" inert={closing} aria-hidden={closing || undefined}>{content}</div>
  </details>;
}
