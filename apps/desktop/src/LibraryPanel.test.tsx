import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { beforeEach, afterEach, it, expect, vi } from "vitest";
import { LibraryPanel } from "./LibraryPanel";
import { emptyLibrary, type LibraryData } from "./providers/library";
const native = vi.hoisted(() => ({ invoke: vi.fn(), indexChanged: null as (() => void) | null, stopIndex: vi.fn() }));
vi.mock("./providers/library", async (importOriginal) => ({
  ...await importOriginal<typeof import("./providers/library")>(),
  watchFileIndex: (callback: () => void) => {
    native.indexChanged = callback;
    return Promise.resolve(native.stopIndex);
  },
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
let root: Root, container: HTMLDivElement, data: LibraryData;
const close = vi.fn();
beforeEach(() => {
  Object.defineProperty(navigator, "language", {
    configurable: true,
    value: "ko-KR",
  });
  data = structuredClone(emptyLibrary);
  close.mockReset();
  native.indexChanged = null;
  native.stopIndex.mockReset();
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  native.invoke
    .mockReset()
    .mockImplementation(async (command: string, args: any) => {
      if (command === "library_load") return structuredClone(data);
      if (command === "library_save_entry") {
        data.entries = [
          args.entry,
          ...data.entries.filter((e) => e.id !== args.entry.id),
        ];
      }
      if (command === "library_delete_entry") {
        data.entries = data.entries.filter((e) => e.id !== args.id);
      }
      if (command === "library_search_files")
        return { items: [], total: 0, limited: false };
    });
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  vi.useRealTimers();
});
async function mount() {
  await act(async () =>
    root.render(
      <LibraryPanel nativeRuntime onClose={close} onChange={() => {}} />,
    ),
  );
}
function button(label: string) {
  return [...container.querySelectorAll("button")].find(
    (b) =>
      b.textContent?.trim() === label || b.getAttribute("aria-label") === label,
  )!;
}
async function click(label: string) {
  await act(async () => button(label).click());
}
async function type(label: string, value: string) {
  const input = container.querySelector<HTMLInputElement | HTMLTextAreaElement>(
    `[aria-label="${label}"]`,
  )!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(
      input instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype,
      "value",
    )!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
it("creates and edits durable snippets and deletes only the confirmed item", async () => {
  await mount();
  await click("스니펫");
  await click("추가");
  await type("항목 이름", "인사말");
  await type("스니펫 내용", "안녕하세요\n반갑습니다");
  await click("저장");
  expect(data.entries).toHaveLength(1);
  expect(container.textContent).toContain("인사말");
  await act(async () =>
    container.querySelector<HTMLButtonElement>(".library-row-main")!.click(),
  );
  await type("스니펫 내용", "고맙습니다");
  await click("저장");
  expect(data.entries[0].value).toBe("고맙습니다");
  await click("인사말 삭제");
  expect(data.entries).toHaveLength(1);
  await click("삭제");
  expect(data.entries).toHaveLength(0);
});
it("preserves editing state on a failed save and requires a decision before dismissing a dirty editor", async () => {
  await mount();
  await click("추가");
  await type("항목 이름", "문서");
  await type("링크 주소", "https://example.com");
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_save_entry") throw "저장 실패";
    return original(command, args);
  });
  await click("저장");
  expect(container.textContent).toContain("저장 실패");
  expect(
    container.querySelector<HTMLInputElement>('[aria-label="항목 이름"]')
      ?.value,
  ).toBe("문서");
  await click("취소");
  expect(container.textContent).toContain("계속 편집");
  expect(close).not.toHaveBeenCalled();
  await click("계속 편집");
  expect(container.querySelector('[aria-label="링크 주소"]')).not.toBeNull();
});
it("ignores stale file-search responses and never displays results from an earlier query", async () => {
  vi.useFakeTimers();
  data.roots = [{ id: "root", path: "/fixture" }];
  let oldResolve: (value: unknown) => void = () => {};
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files" && args.query === "old")
      return new Promise((resolve) => {
        oldResolve = resolve;
      });
    return original(command, args);
  });
  await mount();
  await click("파일 검색");
  await type("보관함 검색", "old");
  await act(async () => vi.advanceTimersByTimeAsync(160));
  await type("보관함 검색", "new");
  await act(async () => vi.advanceTimersByTimeAsync(160));
  await act(async () =>
    oldResolve({
      items: [
        {
          id: "root:old",
          name: "OLD_FILE",
          path: "/fixture/old",
          isDirectory: false,
        },
      ],
      total: 1,
      limited: false,
    }),
  );
  expect(container.textContent).not.toContain("OLD_FILE");
  expect(container.textContent).toContain("일치하는 파일이 없습니다.");
});

const fileA = {
  id: "opaque-a",
  name: "A.txt",
  path: "/fixture/A.txt",
  isDirectory: false,
};
const fileB = {
  id: "opaque-b",
  name: "B.txt",
  path: "/fixture/B.txt",
  isDirectory: false,
};
const preview = (id: string, text: string) => ({
  id,
  name: id,
  path: `/fixture/${id}`,
  isDirectory: false,
  extension: "txt",
  size: 4,
  modifiedAt: null,
  kind: "text",
  text,
  imageDataUrl: null,
  truncated: false,
});
async function advance() {
  await act(async () => vi.advanceTimersByTimeAsync(170));
}
async function key(target: Element, key: string) {
  await act(async () =>
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true })),
  );
}

it("keeps results during refresh, preserves selection, and blocks stale result actions", async () => {
  vi.useFakeTimers();
  const original = native.invoke.getMockImplementation()!;
  let resolveRefresh: (value: unknown) => void = () => {};
  let searches = 0;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files") {
      searches++;
      if (searches === 1)
        return { items: [fileA, fileB], total: 2, limited: false };
      return new Promise((resolve) => {
        resolveRefresh = resolve;
      });
    }
    if (command === "library_preview_file") return preview(args.id, args.id);
    return original(command, args);
  });
  await mount();
  await click("파일 검색");
  await advance();
  const list = container.querySelector('[role="listbox"]')!;
  await key(list, "ArrowDown");
  expect(
    container.querySelector('[aria-selected="true"]')?.textContent,
  ).toContain("B.txt");
  await click("파일 목록 새로고침");
  await advance();
  expect(container.textContent).toContain("A.txt");
  expect(container.textContent).toContain("B.txt");
  await key(list, "Enter");
  expect(
    native.invoke.mock.calls.filter(
      ([command]) => command === "library_file_action",
    ),
  ).toHaveLength(0);
  await act(async () =>
    resolveRefresh({ items: [fileA, fileB], total: 2, limited: false }),
  );
  expect(
    container.querySelector('[aria-selected="true"]')?.textContent,
  ).toContain("B.txt");
  await key(list, "Enter");
  expect(native.invoke).toHaveBeenCalledWith("library_file_action", {
    id: "opaque-b",
    action: "open",
  });
});

it("discards stale previews, treats HTML as text, and clears removed selections", async () => {
  vi.useFakeTimers();
  let resolveOld: (value: unknown) => void = () => {};
  let searches = 0;
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files")
      return ++searches === 1
        ? { items: [fileA, fileB], total: 2, limited: false }
        : { items: [fileA], total: 1, limited: false };
    if (command === "library_preview_file") {
      if (args.id === fileA.id)
        return new Promise((resolve) => {
          resolveOld = resolve;
        });
      return preview(args.id, "<script>bad()</script>");
    }
    return original(command, args);
  });
  await mount();
  await click("파일 검색");
  await advance();
  await key(container.querySelector('[role="listbox"]')!, "ArrowDown");
  expect(container.querySelector(".library-file-text")?.textContent).toBe(
    "<script>bad()</script>",
  );
  expect(container.querySelector("script")).toBeNull();
  await act(async () => resolveOld(preview(fileA.id, "STALE_PREVIEW")));
  expect(container.textContent).not.toContain("STALE_PREVIEW");
  await type("보관함 검색", "A");
  await advance();
  expect(
    container.querySelector('[aria-selected="true"]')?.textContent,
  ).toContain("A.txt");
  expect(container.textContent).not.toContain("bad()");
});

it("passes type filters to native search and retains the last page on failure", async () => {
  vi.useFakeTimers();
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files") {
      if (args.fileType === "image") throw "검색 실패";
      return { items: [fileA], total: 1, limited: false };
    }
    if (command === "library_preview_file") return preview(args.id, "text");
    return original(command, args);
  });
  await mount();
  await click("파일 검색");
  await advance();
  const select = container.querySelector<HTMLSelectElement>(
    '[aria-label="파일 종류"]',
  )!;
  await act(async () => {
    select.value = "image";
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await advance();
  expect(native.invoke).toHaveBeenCalledWith("library_search_files", {
    query: "",
    offset: 0,
    limit: 40,
    fileType: "image",
  });
  expect(container.textContent).toContain("A.txt");
  expect(container.textContent).toContain("검색 실패");
  expect(button("열기").disabled).toBe(true);
});

it("keeps delete confirmation after failure and retries that deletion explicitly", async () => {
  data.entries = [
    { id: "saved", kind: "snippet", title: "Saved", value: "value" },
  ];
  const original = native.invoke.getMockImplementation()!;
  let attempts = 0;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_delete_entry" && ++attempts === 1)
      throw "삭제 실패";
    return original(command, args);
  });
  await mount();
  await click("스니펫");
  await click("Saved 삭제");
  await click("삭제");
  expect(container.textContent).toContain("삭제 실패");
  expect(data.entries).toHaveLength(1);
  await click("삭제");
  expect(data.entries).toHaveLength(0);
});

it("refreshes on native events without idle polling and unsubscribes after leaving Files", async () => {
  vi.useFakeTimers();
  const original = native.invoke.getMockImplementation()!;
  let searches = 0;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files") return ++searches === 1
      ? { items: [fileA], total: 1, limited: false, indexing: true }
      : { items: [fileA, fileB], total: 2, limited: false, indexing: false };
    if (command === "library_preview_file") return preview(args.id, "text");
    return original(command, args);
  });
  await mount(); await click("파일 검색"); await advance();
  expect(container.textContent).toContain("검색 결과가 추가될 수 있습니다.");
  expect(container.querySelectorAll('[role="option"]')).toHaveLength(1);
  const beforeIdle = searches;
  await act(async () => vi.advanceTimersByTimeAsync(12000));
  expect(searches).toBe(beforeIdle);
  await act(async () => native.indexChanged?.());
  await advance();
  expect(container.querySelectorAll('[role="option"]')).toHaveLength(2);
  expect(container.textContent).not.toContain("검색 결과가 추가될 수 있습니다.");
  await click("링크");
  expect(native.stopIndex).toHaveBeenCalledOnce();
  const before = searches;
  await act(async () => native.indexChanged?.());
  await act(async () => vi.advanceTimersByTimeAsync(8000));
  expect(searches).toBe(before);
});

it("clears revoked-root rows while replacement results are pending", async () => {
  vi.useFakeTimers();
  data.roots = [{ id: "root", path: "/fixture" }];
  const original = native.invoke.getMockImplementation()!;
  let searches = 0;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_remove_root") { data.roots = []; return; }
    if (command === "library_search_files") {
      if (++searches === 1) return { items: [fileA], total: 1, limited: false };
      return new Promise(() => {});
    }
    if (command === "library_preview_file") return preview(args.id, "private text");
    return original(command, args);
  });
  await mount(); await click("파일 검색"); await advance();
  expect(container.textContent).toContain("private text");
  await act(async () => { container.querySelector("details")!.open = true; });
  await click("/fixture 검색 제외"); await advance();
  expect(container.querySelectorAll('[role="option"]')).toHaveLength(0);
  expect(container.textContent).not.toContain("private text");
});

it("opens a compact direct Files view with explicit access to Library tabs and folders", async () => {
  vi.useFakeTimers();
  await act(async () => root.render(<LibraryPanel nativeRuntime initialTab="files" onClose={close} onChange={() => {}} />));
  await advance();
  expect(container.querySelector(".library-tabs")).toBeNull();
  expect(container.querySelector("details")!.open).toBe(false);
  await click("보관함");
  expect(container.querySelector(".library-tabs")).not.toBeNull();
  await click("스니펫");
  expect(container.querySelector('[role="listbox"]')).toBeNull();
});

it("does not open a file on an IME composition Enter", async () => {
  vi.useFakeTimers();
  const original = native.invoke.getMockImplementation()!;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files") return { items: [fileA], total: 1, limited: false };
    if (command === "library_preview_file") return preview(args.id, "text");
    return original(command, args);
  });
  await mount(); await click("파일 검색"); await advance();
  await act(async () => container.querySelector('[role="listbox"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true })));
  expect(native.invoke.mock.calls.filter(([command]) => command === "library_file_action")).toHaveLength(0);
});

it("defers native event refresh while unfocused and catches up on focus", async () => {
  vi.useFakeTimers();
  await mount(); await click("파일 검색"); await advance();
  await act(async () => window.dispatchEvent(new Event("blur")));
  const count = () => native.invoke.mock.calls.filter(([command]) => command === "library_search_files").length;
  const before = count();
  await act(async () => native.indexChanged?.());
  await act(async () => vi.advanceTimersByTimeAsync(12000));
  expect(count()).toBe(before);
  await act(async () => window.dispatchEvent(new Event("focus")));
  await advance();
  expect(count()).toBeGreaterThan(before);
});


it("offers broader search alongside local matches, keeps rows pending, and resets scope for a new query", async () => {
  vi.useFakeTimers();
  const original = native.invoke.getMockImplementation()!;
  let resolveBroad!: (value: unknown) => void;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files") {
      if (args.includeSystem) return new Promise((resolve) => { resolveBroad = resolve; });
      return { items: [fileA], total: 1, limited: false };
    }
    if (command === "library_preview_file") return preview(args.id, "text");
    return original(command, args);
  });
  await mount(); await click("파일 검색");
  await type("보관함 검색", "report"); await advance();
  expect(container.querySelectorAll('[role="option"]')).toHaveLength(1);
  expect(button("더 넓게 검색")).toBeTruthy();
  expect(native.invoke.mock.calls.filter(([command, args]) => command === "library_search_files" && args.includeSystem)).toHaveLength(0);
  await click("더 넓게 검색"); await advance();
  expect(container.textContent).toContain("A.txt");
  expect(button("열기").disabled).toBe(true);
  expect(native.invoke).toHaveBeenLastCalledWith("library_search_files", { query: "report", offset: 0, limit: 40, fileType: "all", includeSystem: true });
  await act(async () => resolveBroad({ items: [fileA, fileB], total: 2, limited: true }));
  expect(container.querySelectorAll('[role="option"]')).toHaveLength(2);
  expect(button("인덱스에서만 검색").getAttribute("aria-pressed")).toBe("true");
  await type("보관함 검색", "new"); await advance();
  expect(button("더 넓게 검색").getAttribute("aria-pressed")).toBe("false");
  expect(native.invoke.mock.calls.filter(([command]) => command === "library_search_files").at(-1)?.[1]).not.toHaveProperty("includeSystem");
});

it("ignores a late broader result after returning to indexed search", async () => {
  vi.useFakeTimers();
  const original = native.invoke.getMockImplementation()!;
  let resolveBroad!: (value: unknown) => void;
  native.invoke.mockImplementation(async (command, args) => {
    if (command === "library_search_files") {
      if (args.includeSystem) return new Promise((resolve) => { resolveBroad = resolve; });
      return { items: [fileA], total: 1, limited: false };
    }
    if (command === "library_preview_file") return preview(args.id, "text");
    return original(command, args);
  });
  await mount(); await click("파일 검색"); await type("보관함 검색", "report"); await advance();
  await click("더 넓게 검색"); await advance();
  await click("인덱스에서만 검색"); await advance();
  await act(async () => resolveBroad({ items: [fileB], total: 1, limited: true }));
  expect(container.textContent).toContain("A.txt");
  expect(container.textContent).not.toContain("B.txt");
});
