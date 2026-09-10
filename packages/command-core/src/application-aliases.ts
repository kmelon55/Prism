import catalog from "./application-aliases.json";
import { normalizeSearchText } from "./text-matching";

// Exact app-name variants avoid assigning browser aliases to unrelated helper apps.
const aliasesByName = new Map(catalog.flatMap(({ names, aliases }) =>
  names.map((name) => [normalizeSearchText(name), aliases] as const)));

export function commonApplicationAliases(name: string): readonly string[] {
  return aliasesByName.get(normalizeSearchText(name)) ?? [];
}
