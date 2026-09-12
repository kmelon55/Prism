import { invoke } from "@tauri-apps/api/core";

/** Keep native windows hidden until their theme and first rendered frame are ready. */
export function prepareWindowPresentation(dark: boolean, blur: number, opacity = 64): () => void {
  let cancelled = false;
  let frame = 0;
  let fallback = 0;
  let presented = false;
  const present = () => {
    if (cancelled || presented) return;
    presented = true;
    cancelAnimationFrame(frame);
    window.clearTimeout(fallback);
    void invoke("window_render_ready")
      .catch((error) => console.error("Prism could not present its window", error));
  };
  void invoke<boolean>("prepare_window_appearance", { dark, blur, opacity })
    .then((nativeTint) => {
      if (!cancelled) document.documentElement.dataset.nativeTint = String(nativeTint === true);
    })
    .catch((error) => console.error("Prism could not prepare its native appearance", error))
    .then(() => {
      if (cancelled) return;
      // Hidden WebViews may suspend animation frames. The DOM and native theme
      // are already prepared, so do not make opening depend on their scheduler.
      fallback = window.setTimeout(present, 120);
      // The second callback runs after a paint opportunity for the committed React tree.
      frame = requestAnimationFrame(() => {
        frame = requestAnimationFrame(present);
      });
    });
  return () => {
    cancelled = true;
    cancelAnimationFrame(frame);
    window.clearTimeout(fallback);
  };
}
