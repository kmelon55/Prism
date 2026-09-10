import { act, createRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { LibraryEntryEditor } from "./LibraryEntryEditor";
import { validSnippetKeyword } from "../snippets/copy";
import type { LibraryEntry } from "../providers/library";
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
let root: Root; let container: HTMLDivElement;
const setEditor = vi.fn(); const save = vi.fn(async () => undefined);
beforeEach(() => { vi.clearAllMocks(); localStorage.setItem("prism:preferences", JSON.stringify({ language: "en" })); container = document.createElement("div"); document.body.append(container); root = createRoot(container); });
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount(entry: Partial<LibraryEntry> = {}) { await act(async () => root.render(<LibraryEntryEditor editor={{ id: "one", kind: "snippet", title: "Email", value: "안녕 👋", ...entry }} setEditor={setEditor} busy={false} nativeRuntime={true} input={createRef()} leave={() => undefined} save={save} discard={false} setDiscard={() => undefined} work={async () => undefined} />)); }
it("edits and clears only the optional keyword while preserving Unicode text", async () => {
  await mount({ keyword: ";email" }); const input = container.querySelector<HTMLInputElement>('[aria-label="Abbreviation (optional)"]')!;
  expect(input.value).toBe(";email");
  await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, ""); input.dispatchEvent(new Event("input", { bubbles: true })); });
  expect(setEditor).toHaveBeenCalledWith({ id: "one", kind: "snippet", title: "Email", value: "안녕 👋", keyword: undefined });
});
it("keeps keyword optional and excludes it from link editors", async () => {
  await mount(); expect(container.querySelector<HTMLButtonElement>('button[type="submit"]')!.disabled).toBe(false);
  await mount({ kind: "link", value: "https://example.com" }); expect(container.querySelector('[aria-label="Abbreviation (optional)"]')).toBeNull();
});
it("rejects composing or Unicode keywords and blocks programmatic submit", async () => {
  await mount({ keyword: ";이메일" }); expect(container.querySelector<HTMLButtonElement>('button[type="submit"]')!.disabled).toBe(true);
  await act(async () => container.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
  expect(save).not.toHaveBeenCalled(); expect(container.querySelector('[aria-invalid="true"]')).not.toBeNull();
});
it("matches the canonical case-sensitive ASCII keyword contract", () => {
  for (const value of [undefined, "", ";email", "!EMAIL", "/a:b", ":a_!/-;", `;${"a".repeat(47)}`]) expect(validSnippetKeyword(value)).toBe(true);
  for (const value of ["email", ";", ";a b", ";한", ";e\u0301", ";👋", `;${"a".repeat(48)}`]) expect(validSnippetKeyword(value)).toBe(false);
});
