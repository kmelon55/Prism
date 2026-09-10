import { beforeEach, describe, expect, it, vi } from "vitest";
import { currencyItem, currencyProvider, parseCurrencyQuery, type RateSnapshot } from "./currency";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
const snapshot: RateSnapshot = { date: "2026-09-04", fetchedAt: 1_788_652_800, stale: false, rates: { EUR: 1, USD: 1.25, KRW: 1600, JPY: 200, CNY: 8 } };
beforeEach(() => { invoke.mockReset().mockResolvedValue(snapshot); });

describe("explicit currency intent", () => {
  it.each(["100 USD to KRW", "100달러", "$100", "USD 100 KRW", "100 미국달러 원화", "100 usd in krw", "100 USD → KRW"])("recognizes %s", (query) => {
    expect(parseCurrencyQuery(query)).toEqual([{ amount: 100, from: "USD", to: "KRW" }]);
  });
  it.each([
    ["10,000엔 원화", 10000, "JPY", "KRW"], ["1,000원 to USD", 1000, "KRW", "USD"],
    ["유로 환율", 1, "EUR", "KRW"], ["USD/KRW", 1, "USD", "KRW"],
    ["0.25 USD to EUR", 0.25, "USD", "EUR"], ["-100달러", -100, "USD", "KRW"],
  ])("parses %s", (query, amount, from, to) => {
    expect(parseCurrencyQuery(String(query))).toEqual([{ amount, from, to }]);
  });
  it.each(["", "100", "settings", "dollars file", "100 XYZ", "100 BTC to USD", "1,00 USD", "100 USD xyz", "1e10 USD", "1000000000001 USD", "100 USD\n", "USD " + "x".repeat(130)])("does not interpret %s as a currency request", (query) => {
    expect(parseCurrencyQuery(query)).toEqual([]);
  });
  it("provides an explicit KRW overview including the 100 JPY convention", () => {
    expect(parseCurrencyQuery("환율")).toEqual([
      { amount: 1, from: "USD", to: "KRW" }, { amount: 1, from: "EUR", to: "KRW" },
      { amount: 100, from: "JPY", to: "KRW" }, { amount: 1, from: "CNY", to: "KRW" },
    ]);
  });
});

describe("currency search results", () => {
  it("calculates cross rates and copies exactly the displayed amount", async () => {
    const [item] = await currencyProvider.search("100 USD to KRW", new AbortController().signal);
    expect(item.title).toBe("100 USD = 128,000 KRW");
    expect(item.data?.result).toBe("128000");
    expect(item.subtitle).toContain("2026-09-04 · ECB / Frankfurter");
    expect(item.matchedQuery).toBe("100 USD to KRW");
    expect(invoke).toHaveBeenCalledWith("get_currency_rates");
    expect(invoke.mock.calls[0]).toHaveLength(1); // No amount, pair, or original query leaves the renderer.
  });
  it("rounds to the destination currency's minor units", () => {
    const item = currencyItem({ amount: 1000, from: "KRW", to: "USD" }, snapshot, "1000원 달러");
    expect(item.title).toBe("1,000 KRW = 0.78 USD");
    expect(item.data?.result).toBe("0.78");
  });
  it("labels stale cached data explicitly", () => {
    const item = currencyItem({ amount: 1, from: "EUR", to: "USD" }, { ...snapshot, stale: true }, "EUR USD");
    expect(item.subtitle).toContain("Cached · refresh unavailable · 2026-09-04");
  });
  it("does not request a table for unrelated input or a same-currency conversion", async () => {
    await expect(currencyProvider.search("paper", new AbortController().signal)).resolves.toEqual([]);
    const [item] = await currencyProvider.search("100 USD to USD", new AbortController().signal);
    expect(item.data?.result).toBe("100.00");
    expect(invoke).not.toHaveBeenCalled();
  });
  it("drops a result after the query has been cancelled", async () => {
    let release!: (value: RateSnapshot) => void;
    invoke.mockImplementation(() => new Promise((resolve) => { release = resolve; }));
    const controller = new AbortController();
    const request = currencyProvider.search("100달러", controller.signal);
    controller.abort();
    release(snapshot);
    await expect(request).resolves.toEqual([]);
  });
  it("surfaces a missing currency or network failure instead of inventing a rate", async () => {
    expect(() => currencyItem({ amount: 1, from: "GBP", to: "KRW" }, snapshot, "GBP")).toThrow("unavailable");
    invoke.mockRejectedValue(new Error("Offline"));
    await expect(currencyProvider.search("100달러", new AbortController().signal)).rejects.toThrow("Offline");
  });
});
