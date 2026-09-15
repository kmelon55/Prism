import { expect, it, vi } from "vitest";
import { createClipboardSearchQueue } from "./searchQueue";

it("lets a native request finish but sends only the latest waiting query", async () => {
  let finish!: (value: string) => void;
  const native = vi.fn((query: string) => query === "first" ? new Promise<string>(resolve => { finish = resolve; }) : Promise.resolve(query));
  const search = createClipboardSearchQueue(native);
  const first = new AbortController(), stale = new AbortController(), latest = new AbortController();
  const a = search(first.signal, "first");
  first.abort();
  const b = search(stale.signal, "obsolete");
  stale.abort();
  const c = search(latest.signal, "latest");
  expect(native).toHaveBeenCalledTimes(1);
  finish("first");
  expect(await Promise.all([a,b,c])).toEqual(["first",undefined,"latest"]);
  expect(native.mock.calls.map(([query])=>query)).toEqual(["first","latest"]);
});
