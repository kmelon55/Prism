import type {
  CommandAliasMap,
  CommandItem,
  CommandProvider,
  ProviderFailure,
  SearchResponse,
} from "./types";

import { normalizeSearchText as normalize, subsequenceScore } from "./text-matching";

export function scoreCommand(
  item: CommandItem,
  rawQuery: string,
  aliases: readonly string[] = [],
): number | null {
  const query = normalize(rawQuery.trim());
  const rankingBoost = Number.isFinite(item.rankingBoost)
    ? Math.min(72, Math.max(0, item.rankingBoost ?? 0))
    : 0;
  if (item.matchedQuery !== undefined) {
    return query && normalize(item.matchedQuery.trim()) === query ? 7_000_000 + rankingBoost : null;
  }
  if (!query) return item.favoriteOrder !== undefined ? 1000 - Math.min(100, Math.max(0, item.favoriteOrder)) : rankingBoost;
  const fields = [
    { value: item.title, exact: 6, prefix: 5, fuzzy: 3 },
    ...uniqueAliases(item.searchAliases ?? []).map((value) => ({ value, exact: 6, prefix: 5, fuzzy: 3 })),
    ...uniqueAliases(aliases).map((value) => ({ value, exact: 8, prefix: 4, fuzzy: 2 })),
    { value: item.subtitle ?? "", exact: 1, prefix: 1, fuzzy: 1 },
    { value: item.section, exact: 1, prefix: 1, fuzzy: 1 },
    ...(item.keywords ?? []).map((value) => ({ value, exact: 1, prefix: 1, fuzzy: 1 })),
  ];

  let best: number | null = null;
  for (const field of fields) {
    const value = normalize(field.value);
    if (!value) continue;
    const candidate = subsequenceScore(query, value);
    if (candidate === null) continue;
    const tier = value === query ? field.exact : value.startsWith(query) ? field.prefix : field.fuzzy;
    const weighted = tier * 1_000_000 + 10_000 + Math.max(-10_000, Math.min(candidate, 10_000));
    best = best === null ? weighted : Math.max(best, weighted);
  }

  return best === null ? null : best + rankingBoost + (item.favoriteOrder !== undefined ? 20 : 0);
}

function uniqueAliases(aliases: readonly string[]): string[] {
  const unique = new Set<string>();
  for (const alias of aliases) {
    const normalized = normalize(alias.trim());
    if (normalized) unique.add(normalized);
  }
  return [...unique];
}

export function rankCommands(
  items: CommandItem[],
  query: string,
  aliases: CommandAliasMap = {},
): CommandItem[] {
  return items
    .map((item, index) => {
      const itemAliases = Object.prototype.hasOwnProperty.call(aliases, item.id)
        ? aliases[item.id]
        : undefined;
      return { item, index, score: scoreCommand(item, query, itemAliases) };
    })
    .filter((entry): entry is typeof entry & { score: number } => entry.score !== null)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map(({ item }) => item);
}

export interface SearchOptions {
  timeoutMs?: number;
  onUpdate?: (response: SearchResponse, pendingProviders: number, pendingProviderIds: string[]) => void;
}

export async function searchProviders(
  providers: CommandProvider[],
  query: string,
  signal: AbortSignal,
  aliases: CommandAliasMap = {},
  options: SearchOptions = {},
): Promise<SearchResponse> {
  if (signal.aborted) return { items: [], failures: [] };
  const snapshots: Array<SearchResponse | undefined> = new Array(providers.length);
  let pending = providers.length;
  const snapshot = (): SearchResponse => ({
    items: rankCommands(snapshots.flatMap((result) => result?.items ?? []), query, aliases),
    failures: snapshots.flatMap((result) => result?.failures ?? []),
  });
  if (!pending) options.onUpdate?.(snapshot(), 0, []);

  await Promise.all(providers.map(async (provider, index) => {
    const requestedTimeout = options.timeoutMs ?? provider.timeoutMs;
    const timeoutMs = Number.isFinite(requestedTimeout)
      ? Math.max(1, Math.min(requestedTimeout!, 30_000)) : 500;
    const result = await new Promise<SearchResponse>((resolve) => {
      const controller = new AbortController();
      let finished = false;
      let timer: ReturnType<typeof setTimeout>;
      const finish = (response: SearchResponse) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        signal.removeEventListener("abort", abort);
        resolve(response);
      };
      const abort = () => {
        finish({ items: [], failures: [] });
        controller.abort();
      };
      const failure = (message: string): SearchResponse => ({
        items: [], failures: [{ providerId: provider.id, providerLabel: provider.label, message }],
      });
      timer = setTimeout(() => {
        finish(failure("This source took too long to respond. Try again."));
        controller.abort();
      }, timeoutMs);
      signal.addEventListener("abort", abort, { once: true });
      if (signal.aborted) { abort(); return; }
      // Both synchronous throws and late rejections are observed. A timeout cannot publish twice.
      void Promise.resolve().then(() => controller.signal.aborted ? [] : provider.search(query, controller.signal)).then(
        (items) => finish({ items, failures: [] }),
        (error: unknown) => finish(failure(error instanceof Error ? error.message : "This source could not respond.")),
      );
    });
    if (signal.aborted) return;
    snapshots[index] = result;
    pending -= 1;
    options.onUpdate?.(snapshot(), pending, providers.filter((_, i) => !snapshots[i]).map(({ id }) => id));
  }));
  return signal.aborted ? { items: [], failures: [] } : snapshot();
}
