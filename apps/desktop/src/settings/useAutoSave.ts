import { useEffect, useRef, useState } from "react";

/** Serialize writes and keep the latest edit while a previous write is running. */
export function useAutoSave<T>(save: (value: T) => Promise<unknown>) {
  const saveRef = useRef(save);
  saveRef.current = save;
  const mounted = useRef(false);
  const pending = useRef<{ value: T } | undefined>(undefined);
  const latest = useRef<{ value: T } | undefined>(undefined);
  const running = useRef<Promise<boolean> | undefined>(undefined);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [status, setStatus] = useState<"idle" | "pending" | "saving" | "saved" | "error">("idle");
  const [error, setError] = useState("");

  function flush(): Promise<boolean> {
    clearTimeout(timer.current);
    timer.current = undefined;
    if (running.current) return running.current;
    if (!pending.current) return Promise.resolve(true);
    const work = async () => {
      let succeeded = true;
      while (pending.current) {
        const entry = pending.current;
        pending.current = undefined;
        if (mounted.current) { setStatus("saving"); setError(""); }
        try {
          await saveRef.current(entry.value);
          succeeded = true;
          if (mounted.current && !pending.current) setStatus("saved");
        } catch (error) {
          succeeded = false;
          if (mounted.current && !pending.current) {
            setStatus("error");
            setError(error instanceof Error ? error.message : String(error));
          }
        }
      }
      return succeeded;
    };
    running.current = work().finally(() => { running.current = undefined; });
    return running.current;
  }

  function schedule(value: T, delay = 400) {
    pending.current = latest.current = { value };
    clearTimeout(timer.current);
    if (mounted.current) { setStatus("pending"); setError(""); }
    if (delay === 0) void flush();
    else timer.current = setTimeout(() => { void flush(); }, delay);
  }

  useEffect(() => {
    mounted.current = true;
    const onPageHide = () => { void flush(); };
    window.addEventListener("pagehide", onPageHide);
    return () => {
      mounted.current = false;
      window.removeEventListener("pagehide", onPageHide);
      void flush();
    };
  }, []);

  return { schedule, flush, status, error, retry: () => { if (latest.current) schedule(latest.current.value, 0); } };
}
