import { expect, it, vi } from "vitest";
import type { LibraryEntry } from "../providers/library";
import { createNoteAutosave, noteForStorage } from "./noteAutosave";

const note: LibraryEntry = { id: "note", kind: "note", title: "", value: "" };

it("coalesces pending changes and never writes an older version after a newer one", async () => {
  const complete: (() => void)[] = [];
  const persist = vi.fn(() => new Promise<void>(resolve => complete.push(resolve)));
  const status = vi.fn();
  const autosave = createNoteAutosave(note, persist, status);
  autosave.update({ ...note, value: "first" });
  await Promise.resolve();
  autosave.update({ ...note, value: "middle" });
  autosave.update({ ...note, value: "latest" });
  const leaving = autosave.flush();
  expect(persist).toHaveBeenCalledTimes(1);
  complete[0](); await Promise.resolve();
  expect(persist).toHaveBeenCalledTimes(2);
  expect(persist.mock.calls[1]).toEqual([{ ...note, value: "latest" }]);
  complete[1]();
  expect(await leaving).toBe(true);
  expect(status).toHaveBeenLastCalledWith("saved");
});

it("keeps the latest edit for retry after an in-flight failure", async () => {
  let reject!: (error: unknown) => void;
  const persist = vi.fn<(entry: LibraryEntry) => Promise<void>>()
    .mockImplementationOnce(() => new Promise((_, fail) => { reject = fail; }))
    .mockResolvedValue(undefined);
  const status = vi.fn();
  const autosave = createNoteAutosave(note, persist, status);
  autosave.update({ ...note, value: "first" }); await Promise.resolve();
  autosave.update({ ...note, value: "latest" });
  const pending = autosave.flush();
  reject("Disk full");
  expect(await pending).toBe(false);
  expect(status).toHaveBeenLastCalledWith("error", "Disk full");
  expect(await autosave.flush()).toBe(true);
  expect(persist).toHaveBeenLastCalledWith({ ...note, value: "latest" });
});

it("does not write untouched notes, and persists clearing an existing note", async () => {
  const persist = vi.fn(async () => {});
  const initial = { ...note, title: "Title", value: "Body" };
  const autosave = createNoteAutosave(initial, persist, () => {});
  await autosave.flush();
  expect(persist).not.toHaveBeenCalled();
  autosave.update(note);
  await autosave.flush();
  expect(persist).toHaveBeenCalledWith(note);
});

it("derives a bounded title without changing the body or truncating an explicit title", () => {
  expect(noteForStorage({ ...note, value: "\n메모 첫 줄\n{date}" }, "새 노트"))
    .toMatchObject({ title: "메모 첫 줄", value: "\n메모 첫 줄\n{date}" });
  expect(noteForStorage(note, "새 노트").title).toBe("새 노트");
  expect(noteForStorage({ ...note, value: "🚀".repeat(150) }, "새 노트").title).toBe("🚀".repeat(75));
  expect(noteForStorage({ ...note, title: "a".repeat(100) }, "새 노트").title).toHaveLength(100);
});
