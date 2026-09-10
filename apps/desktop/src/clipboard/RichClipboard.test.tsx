import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ClipboardTypeFilter } from "./ClipboardTypeFilter";
import { ClipboardEntryPreview } from "./ClipboardEntryPreview";
import { searchDurableClipboardHistory } from "../providers/clipboard";

const mocks = vi.hoisted(() => ({ invoke: vi.fn(), native: false }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("../providers/native", () => ({ isTauriRuntime: () => mocks.native, emitClipboardHistorySettingChanged: vi.fn() }));
let root: Root;
let container: HTMLDivElement;
beforeEach(() => {
  vi.clearAllMocks(); mocks.native = false;
  localStorage.setItem("prism:preferences", JSON.stringify({ language: "en" }));
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });

describe("rich clipboard contracts", () => {
  it("sends the type filter to native before limiting results and preserves rich metadata", async () => {
    mocks.invoke.mockResolvedValue([{ id: 7, text: "PNG image · 20 × 30", capturedAtMs: 10, pinned: true, kind: "image", mimeType: "image/png", byteSize: 500, width: 20, height: 30, fileCount: 0, available: true }]);
    expect(await searchDurableClipboardHistory("", 24, "image")).toEqual([{ id: 7, content: "PNG image · 20 × 30", capturedAt: 10, pinned: true, kind: "image", mimeType: "image/png", byteSize: 500, width: 20, height: 30, fileCount: 0, available: true }]);
    expect(mocks.invoke).toHaveBeenLastCalledWith("search_clipboard_history", { query: "", limit: 24, kind: "image" });
    await searchDurableClipboardHistory("file", 4, "all");
    expect(mocks.invoke).toHaveBeenLastCalledWith("search_clipboard_history", { query: "file", limit: 4, kind: null });
  });
  it("offers an accessible controlled type filter without reading clipboard content", async () => {
    const changed = vi.fn();
    await act(async () => root.render(<ClipboardTypeFilter value="all" onChange={changed} />));
    const select = container.querySelector("select")!;
    expect(select.getAttribute("aria-label")).toBe("Clipboard type");
    expect([...select.options].map((option) => option.value)).toEqual(["all", "text", "image", "files"]);
    await act(async () => { select.value = "files"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(changed).toHaveBeenCalledWith("files");
    expect(mocks.invoke).not.toHaveBeenCalled();
  });
  it("explains missing references and renders filenames as text", async () => {
    await act(async () => root.render(<ClipboardEntryPreview entry={{ kind: "files", fileCount: 2, available: false, content: "<img src=x onerror=alert(1)>" }} />));
    expect(container.querySelector('[role="status"]')?.textContent).toContain("missing or unavailable");
    expect(container.textContent).toContain("2 file references. File contents are never stored.");
    expect(container.querySelector("img")).toBeNull();
  });
  it("shows original image metadata and destination support limits", async () => {
    await act(async () => root.render(<ClipboardEntryPreview entry={{ kind: "image", width: 1200, height: 800, mimeType: "image/png", byteSize: 2048 }} />));
    expect(container.textContent).toContain("1200 × 800 · image/png");
    expect(container.textContent).toContain("2.0 KB stored");
    expect(container.textContent).toContain("reuse the original image");
    expect(mocks.invoke).not.toHaveBeenCalled();
  });
  it("loads only selected images and ignores stale image responses", async () => {
    mocks.native = true;
    let first!: (url: string) => void;
    let second!: (url: string) => void;
    mocks.invoke.mockImplementation((_command: string, { id }: { id: number }) => new Promise<string>((resolve) => { if (id === 1) first = resolve; else second = resolve; }));
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 1, kind: "image" }} />));
    expect(mocks.invoke).toHaveBeenLastCalledWith("get_clipboard_history_entry_preview", { id: 1 });
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 2, kind: "image" }} />));
    await act(async () => first("data:image/png;base64,old"));
    expect(container.querySelector("img")).toBeNull();
    await act(async () => second("data:image/png;base64,current"));
    expect(container.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,current");
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 3, kind: "files" }} />));
    expect(container.querySelector("img")).toBeNull();
    expect(mocks.invoke).toHaveBeenCalledTimes(2);
  });
  it("offers a non-destructive preview retry", async () => {
    mocks.native = true;
    mocks.invoke.mockRejectedValueOnce("Image preview is busy. Retry in a moment.").mockResolvedValueOnce("data:image/png;base64,retry");
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 4, kind: "image" }} />));
    expect(container.querySelector('[role="status"]')?.textContent).toContain("Image preview unavailable");
    await act(async () => container.querySelector("button")!.click());
    expect(container.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,retry");
    expect(mocks.invoke).toHaveBeenCalledTimes(2);
  });

  it("fetches complete text only for the selected entry and rejects stale text after switching kinds", async () => {
    mocks.native = true;
    let resolveFirst!: (value: string) => void;
    mocks.invoke.mockImplementationOnce(() => new Promise<string>(resolve => { resolveFirst = resolve; }))
      .mockResolvedValueOnce("<script>plain text</script>\n".repeat(80));
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 1, kind: "text", content: "First preview" }} />));
    expect(mocks.invoke).toHaveBeenLastCalledWith("get_clipboard_history_entry_text", { id: 1 });
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 2, kind: "text", content: "Second preview" }} />));
    expect(container.querySelector(".clipboard-preview-content")?.textContent).toBe("<script>plain text</script>\n".repeat(80));
    expect(container.querySelector("script")).toBeNull();
    await act(async () => root.render(<ClipboardEntryPreview entry={{ id: 3, kind: "files", content: "File preview" }} />));
    await act(async () => resolveFirst("Stale full text"));
    expect(container.textContent).toContain("File preview");
    expect(container.textContent).not.toContain("Stale full text");
    expect(mocks.invoke).toHaveBeenCalledTimes(2);
  });

});
