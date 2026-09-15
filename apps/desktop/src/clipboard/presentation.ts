/** Reveal only after React has committed the destination view. Hidden WebViews may throttle rAF. */
export function afterClipboardRender(reveal: () => void): () => void {
  let finished = false;
  let frame = 0;
  const complete = () => {
    if (finished) return;
    finished = true;
    cancelAnimationFrame(frame);
    window.clearTimeout(fallback);
    reveal();
  };
  const fallback = window.setTimeout(complete, 80);
  frame = requestAnimationFrame(() => { frame = requestAnimationFrame(complete); });
  return () => { finished = true; cancelAnimationFrame(frame); window.clearTimeout(fallback); };
}
