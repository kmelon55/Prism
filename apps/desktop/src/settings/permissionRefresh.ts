import { listen } from "@tauri-apps/api/event";
import { isTauriRuntime } from "../providers/native";

export function watchPermissionChanges(refresh: () => void): () => void {
  const visible = () => { if (document.visibilityState === "visible") refresh(); };
  window.addEventListener("focus", refresh);
  document.addEventListener("visibilitychange", visible);
  let stopped = false;
  let unlisten: (() => void) | undefined;
  if (isTauriRuntime()) void listen("prism:permissions-changed", refresh).then(stop => {
    if (stopped) stop(); else unlisten = stop;
  }).catch(() => {});
  return () => { stopped = true; unlisten?.(); window.removeEventListener("focus", refresh); document.removeEventListener("visibilitychange", visible); };
}
