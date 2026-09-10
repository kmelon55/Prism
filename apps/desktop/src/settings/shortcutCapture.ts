import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

const doubleNames: Record<string, string> = { Control: "DoubleControl", Alt: "DoubleOption", Shift: "DoubleShift", Meta: "DoubleCommand" };
type Key = Pick<KeyboardEvent, "key" | "code" | "ctrlKey" | "altKey" | "shiftKey" | "metaKey" | "repeat" | "isComposing" | "timeStamp">;

// Whisp's 0.42-second release-to-next-press rule, shared by every global recorder.
export class ShortcutCapture {
  private pressed: string | undefined;
  private released: { key: string; time: number } | undefined;
  reset() { this.pressed = undefined; this.released = undefined; }
  keydown(event: Key): string | undefined {
    if (event.repeat) return;
    if (event.isComposing) { this.reset(); return; }
    const modifiers = [event.metaKey ? "Super" : "", event.ctrlKey ? "Control" : "", event.altKey ? "Alt" : "", event.shiftKey ? "Shift" : ""].filter(Boolean);
    if (doubleNames[event.key]) {
      if (modifiers.length !== 1) { this.reset(); return; }
      if (this.pressed === event.key) return;
      this.pressed = event.key;
      if (this.released?.key === event.key && event.timeStamp - this.released.time <= 420 && event.timeStamp >= this.released.time) {
        this.reset(); return doubleNames[event.key];
      }
      this.released = undefined; return;
    }
    this.reset();
    if (!modifiers.length) return "";
    if (!event.code || event.code === "Unidentified") return;
    return [...modifiers, event.code].join("+");
  }
  keyup(event: Key) {
    if (this.pressed === event.key && !event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey && !event.isComposing) {
      this.released = { key: event.key, time: event.timeStamp };
      this.pressed = undefined;
    } else this.reset();
  }
}
export function doubleShortcutKeys(accelerator: string): string[] | undefined {
  const glyph: Record<string, string> = { doublecontrol: "⌃", doubleoption: "⌥", doubleshift: "⇧", doublecommand: "⌘" };
  const key = glyph[accelerator.toLowerCase()]; return key ? [key, key] : undefined;
}

// Serialize begin/end across recorders. A short renewable native lease also
// expires if a WebView closes or crashes without running React cleanup.
let captureQueue = Promise.resolve();
function capture(owner: string, active: boolean) {
  const result = captureQueue.then(() => invoke<void>("set_shortcut_capture", { owner, active }));
  captureQueue = result.catch(() => {}); return result;
}
export function useShortcutCaptureLease(nativeRuntime: boolean, active: boolean, owner: "settings" | "dictation", cancel: () => void) {
  const [ready, setReady] = useState(false);
  const [error, setError] = useState("");
  const cancelRef = useRef(cancel); cancelRef.current = cancel;
  useEffect(() => {
    setReady(!nativeRuntime);
    if (!active) return;
    setError("");
    let alive = true;
    const refresh = () => {
      if (!nativeRuntime) return;
      void capture(owner, true).then(() => { if (alive) setReady(true); }).catch(error => {
        if (alive) { setReady(false); setError(String(error)); cancelRef.current(); }
      });
    };
    refresh();
    const timer = nativeRuntime ? window.setInterval(refresh, 900) : undefined;
    const blur = () => cancelRef.current();
    window.addEventListener("blur", blur);
    return () => {
      alive = false; clearInterval(timer); window.removeEventListener("blur", blur);
      if (nativeRuntime) void capture(owner, false).catch(() => {});
    };
  }, [active, nativeRuntime, owner]);
  return { ready: !nativeRuntime || ready, error };
}
