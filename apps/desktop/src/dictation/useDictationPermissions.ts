import { useEffect, type Dispatch, type SetStateAction } from "react";
import { watchPermissionChanges } from "../settings/permissionRefresh";
import { dictationAction, type DictationStatus } from "./api";

export function useDictationPermissions(nativeRuntime: boolean, setStatus: Dispatch<SetStateAction<DictationStatus | undefined>>, setError: (message: string) => void) {
  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true; let checking = false;
    const refresh = async () => {
      if (checking) return;
      checking = true;
      try {
        const status = await dictationAction("status");
        if (active) setStatus(current => current ? { ...current, microphone: status.microphone, accessibility: status.accessibility, shortcutWarning: status.shortcutWarning } : status);
      } catch (error) { if (active) setError(String(error)); }
      finally { checking = false; }
    };
    void refresh();
    const stop = watchPermissionChanges(() => void refresh());
    const timer = window.setInterval(() => void refresh(), 2000);
    return () => { active = false; stop(); window.clearInterval(timer); };
  }, [nativeRuntime, setStatus, setError]);
}
