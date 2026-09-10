import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { rankCommands } from "@prism/command-core";
import { nativeApplicationProvider, createApplicationAliasProvider, getResolvedNativeIcon, loadNativeIcon } from "./native";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
beforeEach(() => {
  Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
  invoke.mockReset();
});
afterEach(() => { delete window.__TAURI_INTERNALS__; });

describe("native alias resolution", () => {
  it("resolves only aliases matching the query, instead of looking up every configured app", async () => {
    const aliases = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`native:app${i}`, [`shortcut${i}`]]));
    aliases["native:wanted"] = ["paper"];
    invoke.mockResolvedValue({ id: "wanted", name: "Editor", path: "/fixture/Editor.app", platform: "macos", rankingBoost: 0 });
    const results = await createApplicationAliasProvider(aliases).search("paper", new AbortController().signal);
    expect(invoke).toHaveBeenCalledOnce();
    expect(invoke).toHaveBeenCalledWith("get_application", { applicationId: "wanted" });
    expect(results.map(({ id }) => id)).toEqual(["native:wanted"]);
  });

  it("limits in-flight lookups to four and stops starting work after cancellation", async () => {
    const aliases = Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`native:app${i}`, [`paper${i}`]]));
    const release: Array<(value: unknown) => void> = [];
    invoke.mockImplementation(() => new Promise((resolve) => { release.push(resolve); }));
    const controller = new AbortController();
    const search = createApplicationAliasProvider(aliases).search("paper", controller.signal);
    expect(invoke).toHaveBeenCalledTimes(4);
    controller.abort();
    release.forEach((resolve) => resolve(null));
    await expect(search).resolves.toEqual([]);
    expect(invoke).toHaveBeenCalledTimes(4);
  });
});

describe("native artwork loading", () => {
  it("retries a failed IPC request instead of permanently caching a missing icon", async () => {
    const target = "system:settings:notifications";
    invoke.mockRejectedValueOnce(new Error("Loader unavailable"));
    await expect(loadNativeIcon(target)).resolves.toBeUndefined();
    expect(getResolvedNativeIcon(target)).toBeUndefined();
    // Let the queue release the failed request before requesting this view again.
    await vi.waitFor(() => expect(invoke).toHaveBeenCalledTimes(1));
    invoke.mockResolvedValueOnce("data:image/png;base64,fixture");
    await expect(loadNativeIcon(target)).resolves.toBe("data:image/png;base64,fixture");
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(invoke).toHaveBeenLastCalledWith("load_system_icon", { commandId: target });
  });
});


describe("native candidate reranking", () => {
  const chrome = { id: "chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app", platform: "macos", rankingBoost: 0 };
  it.each(["크롬", "ㅋㄹ", "google 크롬"])("preserves native alias candidates through TS reranking for %s", async (query) => {
    invoke.mockResolvedValue([chrome]);
    const candidates = await nativeApplicationProvider.search(query, new AbortController().signal);
    expect(invoke).toHaveBeenCalledWith("search_applications", { query, limit: 40 });
    expect(rankCommands(candidates, query).map(({ id }) => id)).toEqual(["native:chrome"]);
  });
  it("keeps native path matches during TS reranking", async () => {
    invoke.mockResolvedValue([chrome]);
    const candidates = await nativeApplicationProvider.search("/Applications/Google", new AbortController().signal);
    expect(rankCommands(candidates, "/Applications/Google")).toHaveLength(1);
  });
  it("discards native results that complete after cancellation", async () => {
    let release!: (value: unknown) => void;
    invoke.mockImplementation(() => new Promise((resolve) => { release = resolve; }));
    const controller = new AbortController();
    const search = nativeApplicationProvider.search("크롬", controller.signal);
    controller.abort();
    release([chrome]);
    await expect(search).resolves.toEqual([]);
  });
});
