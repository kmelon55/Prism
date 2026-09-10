import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { fileProvider, searchFiles, libraryProvider, emptyLibrary } from "./library";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
const hit = { id: "opaque", name: "Report.txt", path: "/fixture/Report.txt", isDirectory: false };
beforeEach(() => { vi.useFakeTimers(); native.invoke.mockReset(); });
afterEach(() => vi.useRealTimers());
it("returns indexed files immediately alongside explicit broader search without waiting on system search", async () => {
  native.invoke.mockResolvedValue({ items: [hit], total: 1, limited: false });
  const pending = fileProvider.search("report", new AbortController().signal);
  expect(native.invoke).toHaveBeenCalledTimes(1);
  expect(native.invoke).toHaveBeenCalledWith("library_search_files", { query: "report", offset: 0, limit: 8, fileType: "all" });
  const items = await pending;
  expect(items[0].title).toBe("Report.txt");
  expect(items[1]).toMatchObject({ data: { query: "report" }, actions: [{ id: "files-search-broader" }] });
  expect(native.invoke).toHaveBeenCalledTimes(1);
  expect(vi.getTimerCount()).toBe(0);
});
it("offers explicit broader search on a local miss without starting it automatically", async () => {
  native.invoke.mockResolvedValue({ items: [], total: 0, limited: false, indexing: true });
  const items = await fileProvider.search("report", new AbortController().signal);
  expect(items).toHaveLength(1);
  expect(items[0].actions[0].id).toBe("files-search-broader");
  expect(native.invoke).toHaveBeenCalledTimes(1);
});
it("passes broader-search scope, filter and page to the native merger", async () => {
  native.invoke.mockResolvedValue({ items: [hit], total: 1, limited: true });
  await searchFiles("report", 40, 40, "text", true);
  expect(native.invoke).toHaveBeenCalledWith("library_search_files", {
    query: "report", offset: 40, limit: 40, fileType: "text", includeSystem: true,
  });
});
it("does not publish a late local response or broader-search action after cancellation", async () => {
  let complete!: (value: unknown) => void;
  native.invoke.mockImplementation(() => new Promise((resolve) => { complete = resolve; }));
  const controller = new AbortController();
  const pending = fileProvider.search("old", controller.signal);
  controller.abort();
  complete({ items: [], total: 0, limited: false });
  expect(await pending).toEqual([]);
  expect(native.invoke).toHaveBeenCalledTimes(1);
});
it("does no native work for an empty query or already-cancelled request", async () => {
  const controller = new AbortController();
  await fileProvider.search("  ", controller.signal);
  controller.abort();
  await fileProvider.search("report", controller.signal);
  expect(native.invoke).not.toHaveBeenCalled();
});

it("finds a snippet by its saved abbreviation for manual reuse", async () => {
  const provider = libraryProvider({ ...emptyLibrary, entries: [{ id: "greeting", kind: "snippet", title: "Greeting", value: "안녕하세요 👋", keyword: ";hi" }] }, []);
  const items = await provider.search(";hi", new AbortController().signal);
  expect(items).toHaveLength(1);
  expect(items[0].id).toBe("library:greeting");
  expect(items[0].actions.map(action => action.id)).toContain("library-copy");
});
