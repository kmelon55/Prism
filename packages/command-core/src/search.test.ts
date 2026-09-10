import { afterEach, describe, expect, it, vi } from "vitest";
import { commonApplicationAliases } from "./application-aliases";
import { rankCommands, searchProviders } from "./search";
import type { CommandItem, CommandProvider } from "./types";

const item = (id: string, title: string, keywords: string[] = []): CommandItem => ({
  id,
  providerId: "test",
  title,
  section: "Commands",
  kind: "command",
  keywords,
  actions: [{ id: "run", title: "Run" }],
});

describe("rankCommands", () => {
  it("ranks an exact title before a keyword match", () => {
    const ranked = rankCommands(
      [item("keyword", "Open workspace", ["focus"]), item("exact", "Focus")],
      "focus",
    );
    expect(ranked.map(({ id }) => id)).toEqual(["exact", "keyword"]);
  });

  it("supports compact subsequence searches", () => {
    expect(rankCommands([item("prefs", "Open Preferences")], "opref")).toHaveLength(1);
  });

  it("uses a bounded provider boost without turning non-matches into matches", () => {
    const frequent = { ...item("frequent", "Alpha"), rankingBoost: 48 };
    const regular = item("regular", "Alpha");
    expect(rankCommands([regular, frequent], "alpha").map(({ id }) => id)).toEqual([
      "frequent",
      "regular",
    ]);
    expect(rankCommands([frequent], "beta")).toHaveLength(0);
  });

  it("matches a user alias for only its command", () => {
    const commands = [item("browser", "Open Browser"), item("mail", "Open Mail")];

    expect(rankCommands(commands, "web", { browser: ["web"] }).map(({ id }) => id)).toEqual([
      "browser",
    ]);
  });

  it("prioritizes an exact user alias over title and keyword matches", () => {
    const commands = [
      item("keyword", "Open Workspace", ["focus"]),
      item("alias", "Concentrate"),
      item("title", "Focus"),
    ];

    expect(
      rankCommands(commands, "focus", { alias: ["focus"] }).map(({ id }) => id),
    ).toEqual(["alias", "title", "keyword"]);
  });

  it("ignores empty user aliases", () => {
    const commands = [item("browser", "Open Browser")];

    expect(rankCommands(commands, "unmatched", { browser: ["", "   "] })).toEqual([]);
  });

  it("deduplicates normalized aliases without changing stable ordering", () => {
    const commands = [item("first", "First"), item("second", "Second")];
    const ranked = rankCommands(commands, "web", {
      first: ["web", " WEB ", "web"],
      second: ["web"],
    });

    expect(ranked.map(({ id }) => id)).toEqual(["first", "second"]);
  });
});

describe("search intent and tier contracts", () => {
  it("keeps explicit calculator/web results only for their recognized query", () => {
    const result = { ...item("calc", "8"), matchedQuery: "(18 + 6) / 3" };
    expect(rankCommands([result], " (18 + 6) / 3 ")).toEqual([result]);
    expect(rankCommands([result], "8")).toEqual([]);
    expect(rankCommands([result], "")).toEqual([]);
    const url = { ...item("url", "Open a destination"), matchedQuery: "https://example.org/a" };
    expect(rankCommands([url], "https://example.org/a")).toEqual([url]);
  });

  it("prevents frequency boosts and long fuzzy scores from crossing match tiers", () => {
    const frequent = { ...item("prefix", "Calendar"), rankingBoost: 1_000_000 };
    expect(rankCommands([frequent, item("exact", "Cal"), item("alias", "Paper Notes")], "cal", {
      alias: ["cal"],
    }).map(({ id }) => id)).toEqual(["alias", "exact", "prefix"]);
  });

  it("normalizes composed and decomposed Hangul consistently", () => {
    const command = item("ko", "한글 메모");
    expect(rankCommands([command], "한글".normalize("NFD"))).toEqual([command]);
    expect(rankCommands([command], "노트", { ko: ["노트".normalize("NFD")] })).toEqual([command]);
  });
});

describe("searchProviders", () => {
  afterEach(() => { vi.useRealTimers(); });

  it("allows a network deadline while keeping local source deadlines short", async () => {
    vi.useFakeTimers();
    const updates = vi.fn();
    const search = searchProviders([
      { id: "local", label: "Local", search: () => new Promise(() => undefined) },
      { id: "rates", label: "Rates", timeoutMs: 5000, search: () => new Promise((resolve) => {
        setTimeout(() => resolve([item("conversion", "Conversion")]), 800);
      }) },
    ], "", new AbortController().signal, {}, { onUpdate: updates });
    await vi.advanceTimersByTimeAsync(500);
    expect(updates.mock.calls.at(-1)?.[0].failures[0].providerId).toBe("local");
    expect(updates.mock.calls.at(-1)?.[1]).toBe(1);
    await vi.advanceTimersByTimeAsync(300);
    const result = await search;
    expect(result.items[0].id).toBe("conversion");
    expect(result.failures).toHaveLength(1);
  });

  it("publishes fast results while another source is still running", async () => {
    let release!: (items: CommandItem[]) => void;
    const updates = vi.fn();
    const search = searchProviders([
      { id: "slow", label: "Slow", search: () => new Promise((resolve) => { release = resolve; }) },
      { id: "fast", label: "Fast", search: async () => [item("fast", "Fast")] },
    ], "", new AbortController().signal, {}, { onUpdate: updates });
    await vi.waitFor(() => expect(updates).toHaveBeenCalledOnce());
    expect(updates.mock.calls[0][0].items.map((item: CommandItem) => item.id)).toEqual(["fast"]);
    expect(updates.mock.calls[0][1]).toBe(1);
    expect(updates.mock.calls[0][2]).toEqual(["slow"]);
    release([item("slow", "Slow")]);
    const result = await search;
    // Deterministic provider ordering does not depend on completion order.
    expect(result.items.map(({ id }) => id)).toEqual(["slow", "fast"]);
    expect(updates.mock.calls.at(-1)?.[1]).toBe(0);
  });

  it("times out a stuck source, aborts its work and ignores late completion", async () => {
    vi.useFakeTimers();
    let release!: (items: CommandItem[]) => void;
    let childSignal!: AbortSignal;
    const updates = vi.fn();
    const search = searchProviders([
      { id: "stuck", label: "Stuck", search: (_query, signal) => {
        childSignal = signal;
        return new Promise((resolve) => { release = resolve; });
      } },
      { id: "ok", label: "Okay", search: async () => [item("ok", "Okay")] },
    ], "", new AbortController().signal, {}, { onUpdate: updates, timeoutMs: 500 });
    await vi.advanceTimersByTimeAsync(500);
    const result = await search;
    expect(childSignal.aborted).toBe(true);
    expect(result.items.map(({ id }) => id)).toEqual(["ok"]);
    expect(result.failures[0].providerId).toBe("stuck");
    const count = updates.mock.calls.length;
    release([item("late", "Late")]);
    await vi.advanceTimersByTimeAsync(10);
    expect(updates).toHaveBeenCalledTimes(count);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("propagates parent cancellation and never publishes afterward", async () => {
    const controller = new AbortController();
    let childSignal!: AbortSignal;
    const updates = vi.fn();
    const search = searchProviders([{ id: "cancel", label: "Cancel", search: (_query, signal) => {
      childSignal = signal;
      return new Promise(() => undefined);
    } }], "", controller.signal, {}, { onUpdate: updates });
    await Promise.resolve();
    controller.abort();
    await expect(search).resolves.toEqual({ items: [], failures: [] });
    expect(childSignal.aborted).toBe(true);
    expect(updates).not.toHaveBeenCalled();
  });

  it("isolates synchronous exceptions and accepts an empty provider list", async () => {
    const result = await searchProviders([{ id: "broken", label: "Broken", search: () => { throw new Error("Broken fixture"); } }], "", new AbortController().signal);
    expect(result.failures[0].message).toBe("Broken fixture");
    const update = vi.fn();
    await searchProviders([], "", new AbortController().signal, {}, { onUpdate: update });
    expect(update).toHaveBeenCalledWith({ items: [], failures: [] }, 0, []);
  });
  it("keeps successful results when one provider fails", async () => {
    const providers: CommandProvider[] = [
      { id: "ok", label: "Okay", search: async () => [item("focus", "Focus")] },
      { id: "bad", label: "Broken", search: async () => Promise.reject(new Error("Offline")) },
    ];
    const response = await searchProviders(providers, "", new AbortController().signal);
    expect(response.items).toHaveLength(1);
    expect(response.failures).toEqual([
      { providerId: "bad", providerLabel: "Broken", message: "Offline" },
    ]);
  });

  it("ranks with aliases without mutating provider-owned commands", async () => {
    const command = item("browser", "Open Browser");
    const providers: CommandProvider[] = [
      { id: "apps", label: "Applications", search: async () => [command] },
    ];

    const response = await searchProviders(
      providers,
      "web",
      new AbortController().signal,
      { browser: ["web"] },
    );

    expect(response.items).toEqual([command]);
    expect(response.items[0]).toBe(command);
    expect(command).not.toHaveProperty("aliases");
  });

  it("returns promptly with no results or failures once cancellation wins", async () => {
    const controller = new AbortController();
    const providers: CommandProvider[] = [
      { id: "late", label: "Late", search: () => new Promise(() => undefined) },
    ];

    const response = searchProviders(providers, "web", controller.signal, {
      browser: ["web"],
    });
    controller.abort();

    await expect(response).resolves.toEqual({ items: [], failures: [] });
  });
});

it("orders empty-search favorites before usage boosts without overriding exact query matches", () => {
  const first={...item("first","Pinned document"),favoriteOrder:0};
  const second={...item("second","Pinned browser"),favoriteOrder:1};
  const recent={...item("recent","Browser"),rankingBoost:72};
  expect(rankCommands([recent,second,first],"").map(i=>i.id)).toEqual(["first","second","recent"]);
  expect(rankCommands([second,recent],"Browser")[0].id).toBe("recent");
  expect(rankCommands([first],"unrelated")).toEqual([]);
});


describe("Korean and Unicode search", () => {
  const chrome = { ...item("chrome", "Google Chrome"), searchAliases: commonApplicationAliases("Google Chrome") };
  it.each(["크롬", "ㅋㄹ", "크ㄹ", "구글 ㅋㄹ", "google 크롬", "google ㅋㄹ", "크롬".normalize("NFD"), "Ｇｏｏｇｌｅ Ｃｈｒｏｍｅ"])("matches Chrome with %s", (query) => {
    expect(rankCommands([chrome], query)).toEqual([chrome]);
  });
  it("keeps common alias initials competitive with a large set of title candidates", () => {
    const apps = Array.from({ length: 60 }, (_, i) => item(`weak${i}`, `크롬 도구 ${i}`));
    expect(rankCommands([...apps, chrome], "ㅋㄹ")[0]).toBe(chrome);
  });
  it("matches complete Korean syllables literally and initials without cross-syllable vowel matches", () => {
    const korean = item("ko", "한글 메모");
    expect(rankCommands([korean], "ㅎㄱ ㅁㅁ")).toEqual([korean]);
    expect(rankCommands([korean], "한ㄱ 메ㅁ")).toEqual([korean]);
    expect(rankCommands([korean], "하글")).toEqual([]);
    expect(rankCommands([korean], "ㅏ")).toEqual([]);
  });
  it("folds accents, compatibility characters and astral characters consistently", () => {
    const unicode = item("unicode", "Café 🚀 Notes");
    expect(rankCommands([unicode], "cafe 🚀")).toEqual([unicode]);
    expect(rankCommands([unicode], "🚀n")).toEqual([unicode]);
  });
  it("gives explicit aliases priority over common aliases despite frecency", () => {
    const explicit = item("custom", "My Browser");
    expect(rankCommands([{ ...chrome, rankingBoost: Number.MAX_VALUE }, explicit], "크롬", {
      custom: ["크롬"],
    }).map(({ id }) => id)).toEqual(["custom", "chrome"]);
    expect(rankCommands([chrome], "파이어폭스")).toEqual([]);
    expect(commonApplicationAliases("Google Chrome Helper")).toEqual([]);
  });
  it("keeps a common alias exact match above a frequent prefix match", () => {
    expect(rankCommands([{ ...item("prefix", "크롬 확장"), rankingBoost: 72 }, chrome], "크롬")[0]).toBe(chrome);
  });
});
