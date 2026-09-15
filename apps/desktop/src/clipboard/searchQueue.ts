/** One native query per window. Superseded waiting queries never cross IPC. */
export function createClipboardSearchQueue<TArgs extends unknown[], TResult>(search: (...args: TArgs) => Promise<TResult>) {
  let active: Promise<TResult> | undefined;
  return async (signal: AbortSignal, ...args: TArgs): Promise<TResult | undefined> => {
    while (active) {
      await active.catch(() => undefined);
      if (signal.aborted) return undefined;
    }
    if (signal.aborted) return undefined;
    const request = search(...args);
    active = request;
    try { return await request; }
    finally { if (active === request) active = undefined; }
  };
}
