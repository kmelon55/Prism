import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import type { CommandItem, CommandProvider } from "@prism/command-core";

export const currencyActionIds = { copyResult: "copy-currency-result" } as const;
const codes = "AUD BRL CAD CHF CNY CZK DKK EUR GBP HKD HUF IDR ILS INR ISK JPY KRW MXN MYR NOK NZD PHP PLN RON SEK SGD THB TRY USD ZAR".split(" ");
const aliases: Record<string, string> = {
  ...Object.fromEntries(codes.map((code) => [code.toLowerCase(), code])),
  달러: "USD", 미국달러: "USD", 원: "KRW", 원화: "KRW", 엔: "JPY", 엔화: "JPY",
  유로: "EUR", 위안: "CNY", 위안화: "CNY", 파운드: "GBP",
  "$": "USD", "₩": "KRW", "€": "EUR", "£": "GBP",
};
const token = Object.keys(aliases).sort((a, b) => b.length - a.length)
  .map((value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
const number = "[+-]?(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d{1,6})?";
const destination = `(?:\\s*(?:to|in|->|→|/|=)?\\s*(${token}))?`;
const amountFirst = new RegExp(`^(${number})\\s*(${token})${destination}$`, "iu");
const currencyFirst = new RegExp(`^(${token})\\s*(${number})${destination}$`, "iu");
const pair = new RegExp(`^(${token})${destination}$`, "iu");

export interface CurrencyIntent { amount: number; from: string; to: string }
export interface RateSnapshot { date: string; fetchedAt: number; rates: Record<string, number>; stale: boolean }

export function parseCurrencyQuery(query: string): CurrencyIntent[] {
  if (query.length > 128 || /[\u0000-\u001f\u007f]/u.test(query)) return [];
  const text = query.trim().toLowerCase();
  if (text === "환율" || text === "exchange rates") {
    return ["USD", "EUR", "JPY", "CNY"].map((from) => ({ amount: from === "JPY" ? 100 : 1, from, to: "KRW" }));
  }
  const expression = text.replace(/\s*환율$/u, "").trim();
  const suffix = amountFirst.exec(expression);
  const prefix = suffix ? null : currencyFirst.exec(expression);
  const currencies = suffix || prefix ? null : pair.exec(expression);
  if (!suffix && !prefix && !currencies) return [];
  const amount = Number((suffix?.[1] ?? prefix?.[2] ?? "1").replaceAll(",", ""));
  const from = aliases[suffix?.[2] ?? prefix?.[1] ?? currencies![1]];
  const target = suffix?.[3] ?? prefix?.[3] ?? currencies?.[2];
  const to = target ? aliases[target] : from === "KRW" ? "USD" : "KRW";
  if (!Number.isFinite(amount) || Math.abs(amount) > 1e12) return [];
  return [{ amount, from, to }];
}

const amountLabel = (amount: number) => new Intl.NumberFormat("en-US", { maximumFractionDigits: 6 }).format(amount);

export function currencyItem(intent: CurrencyIntent, snapshot: RateSnapshot | undefined, query: string): CommandItem {
  const { amount, from, to } = intent;
  const fromRate = snapshot?.rates[from];
  const toRate = snapshot?.rates[to];
  if (from !== to && (!fromRate || !toRate || !Number.isFinite(fromRate) || !Number.isFinite(toRate) || fromRate <= 0 || toRate <= 0)) {
    throw new Error(`A reference rate for ${from}/${to} is unavailable.`);
  }
  const result = from === to ? amount : amount * toRate! / fromRate!;
  if (!Number.isFinite(result)) throw new Error(t("This amount is too large to convert."));
  const digits = new Intl.NumberFormat("en-US", { style: "currency", currency: to }).resolvedOptions().maximumFractionDigits ?? 2;
  // Copy exactly the displayed number, without a thousands separator or currency label.
  const copyValue = result.toFixed(digits);
  const formatted = new Intl.NumberFormat("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(Number(copyValue));
  const source = from === to ? t("Same currency · no exchange rate needed")
    : t("{0}{1} · ECB / Frankfurter · Daily reference rate", {"0": snapshot!.stale ? "Cached · refresh unavailable · " : "","1": snapshot!.date});
  return {
    id: `currency:${from}:${to}`, providerId: "currency", section: "Currency", kind: "command",
    title: `${amountLabel(amount)} ${from} = ${formatted} ${to}`, subtitle: source,
    matchedQuery: query.trim(), icon: "currency", accent: "mint",
    answer: {
      kind: "currency", input: amountLabel(amount), inputUnit: from, value: formatted, unit: to,
      context: from === to ? t("Same currency") : `1 ${from} = ${amountLabel(toRate! / fromRate!)} ${to}`,
      note: source, stale: snapshot?.stale,
    },
    data: { result: copyValue },
    actions: [{ id: currencyActionIds.copyResult, title: t("Copy amount"), shortcut: ["↵"], style: "accent" }],
  };
}

export const currencyProvider: CommandProvider = {
  id: "currency", get label() { return t("Exchange rates"); }, timeoutMs: 5_000,
  async search(query, signal) {
    const intents = parseCurrencyQuery(query);
    if (signal.aborted || !intents.length) return [];
    // Native code fetches a fixed table; user queries, amounts, and pairs stay on this device.
    const snapshot = intents.some(({ from, to }) => from !== to)
      ? await invoke<RateSnapshot>("get_currency_rates") : undefined;
    if (signal.aborted) return [];
    return intents.map((intent) => currencyItem(intent, snapshot, query));
  },
};
