import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { LibraryRunDialog, needsLibraryRun } from "./LibraryRunDialog";
import type { LibraryEntry } from "../providers/library";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
let root: Root, host: HTMLDivElement;
const completed = vi.fn(),
  close = vi.fn();
const link: LibraryEntry = {
  id: "link",
  title: "Search",
  kind: "link",
  value: "https://example.com/?q={query}",
};
beforeEach(() => {
  vi.useFakeTimers();
  Object.defineProperty(navigator, "language", {
    configurable: true,
    value: "ko-KR",
  });
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  completed.mockReset();
  close.mockReset();
  native.invoke.mockReset();
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.useRealTimers();
});
async function mount(entry = link) {
  await act(async () =>
    root.render(
      <LibraryRunDialog
        entry={entry}
        action={entry.kind === "snippet" ? "copy" : "open"}
        nativeRuntime
        onClose={close}
        onComplete={completed}
      />,
    ),
  );
}
async function type(value: string) {
  const input = host.querySelector("input")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value",
    )!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
async function tick() {
  await act(async () => vi.advanceTimersByTimeAsync(160));
}
async function submit() {
  await act(async () =>
    host
      .querySelector("form")!
      .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })),
  );
}
it("leaves parameterless entries direct and identifies supported dynamic templates", () => {
  expect(needsLibraryRun(link)).toBe(true);
  expect(needsLibraryRun({ ...link, value: "https://example.com" })).toBe(
    false,
  );
  expect(
    needsLibraryRun({ ...link, kind: "snippet", value: "{date} {clipboard}" }),
  ).toBe(true);
  expect(
    needsLibraryRun({ ...link, kind: "path", value: "/some/{query}" }),
  ).toBe(false);
});
it("never runs on mount and executes only the latest confirmed query token", async () => {
  let oldResolve: (value: unknown) => void = () => {};
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_prepare_entry")
      return args.query === "old"
        ? new Promise((resolve) => {
            oldResolve = resolve;
          })
        : { token: "latest", value: "https://example.com/?q=new" };
  });
  await mount();
  await tick();
  expect(native.invoke).not.toHaveBeenCalled();
  await type("old");
  await tick();
  await type("new");
  await tick();
  await act(async () => oldResolve({ token: "stale", value: "STALE" }));
  expect(host.textContent).not.toContain("STALE");
  expect(
    native.invoke.mock.calls.some(
      ([command]) => command === "library_run_entry",
    ),
  ).toBe(false);
  await submit();
  expect(native.invoke).toHaveBeenCalledWith("library_run_entry", {
    id: "link",
    action: "open",
    token: "latest",
  });
  expect(completed).toHaveBeenCalledWith("open");
});
it("invalidates the preview immediately when input changes and blocks duplicate execution", async () => {
  let done: () => void = () => {};
  native.invoke.mockImplementation(async (command) =>
    command === "library_prepare_entry"
      ? { token: "token", value: "preview" }
      : new Promise<void>((resolve) => {
          done = resolve;
        }),
  );
  await mount();
  await type("first");
  await tick();
  await type("second");
  await submit();
  expect(
    native.invoke.mock.calls.filter(
      ([command]) => command === "library_run_entry",
    ),
  ).toHaveLength(0);
  await tick();
  await submit();
  await submit();
  expect(
    native.invoke.mock.calls.filter(
      ([command]) => command === "library_run_entry",
    ),
  ).toHaveLength(1);
  await act(async () => done());
});
it("requires a fresh preview after a failed execution and preserves the error", async () => {
  native.invoke.mockImplementation(async (command) => {
    if (command === "library_run_entry") throw "항목이 변경되었습니다.";
    return { token: "token", value: "2026-09-09 clipboard" };
  });
  await mount({ ...link, kind: "snippet", value: "{date} {clipboard}" });
  await tick();
  await submit();
  expect(host.textContent).toContain("항목이 변경되었습니다.");
  expect(
    host.querySelector<HTMLButtonElement>('button[type="submit"]')!.disabled,
  ).toBe(true);
  expect(completed).not.toHaveBeenCalled();
});
