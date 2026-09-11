import { rankCommands, scoreCommand, type CommandAliasMap, type CommandItem } from "@prism/command-core";

export type PaletteView = "root" | "clipboard";

interface RootLocation {
  query: string;
  items: CommandItem[];
  selectedIndex: number;
  scrollTop: number;
}

export interface PaletteNavigation {
  view: PaletteView;
  query: string;
  items: CommandItem[];
  selectedIndex: number;
  generation: number;
  pending: boolean;
  selectionTouched: boolean;
  scrollTop: number;
  scrollRevision: number;
  parent?: RootLocation;
}

export type NavigationEvent =
  | { type: "query"; query: string; aliases?: CommandAliasMap }
  | { type: "select"; index: number | ((current: number) => number) }
  | { type: "results"; generation: number; items: CommandItem[]; pendingProviderIds?: string[]; aliases?: CommandAliasMap }
  | { type: "clipboard"; scrollTop: number }
  | { type: "back" }
  | { type: "reset" };

export function clampIndex(index: number, length: number): number {
  return Math.max(0, Math.min(index, length - 1));
}

/** Keep launcher entries above files, preserving match quality inside each group. */
export function rankPaletteResults(items: CommandItem[], query: string, aliases: CommandAliasMap = {}, selectedId?: string): CommandItem[] {
  let supplementalFiles = 0;
  return rankCommands(items, query, aliases)
    .map((item, index) => ({ item, index, score: scoreCommand(item, query, Object.hasOwn(aliases, item.id) ? aliases[item.id] : undefined)! }))
    .sort((a, b) => {
      const updatePriority = !query.trim()
        ? Number(b.item.providerId === "prism-update") - Number(a.item.providerId === "prism-update") : 0;
      return updatePriority || Number(a.item.kind === "file" || a.item.providerId === "files") - Number(b.item.kind === "file" || b.item.providerId === "files")
        || b.score - a.score || a.index - b.index;
    })
    .filter(({ item, score }) => item.kind !== "file" || !query.trim() || score >= 6_000_000 || ++supplementalFiles <= 8 || item.id === selectedId)
    .map(({ item }) => item);
}

export function initialNavigation(items: CommandItem[] = []): PaletteNavigation {
  return {
    view: "root", query: "", items, selectedIndex: 0, generation: 0,
    pending: false, selectionTouched: false, scrollTop: 0, scrollRevision: 0,
  };
}

export function navigate(state: PaletteNavigation, event: NavigationEvent): PaletteNavigation {
  switch (event.type) {
    case "query": {
      if (event.query === state.query) return state;
      const items = (state.view === "root" ? rankPaletteResults : rankCommands)(state.items, event.query, event.aliases);
      return {
        ...state, query: event.query, items, selectedIndex: 0, pending: true, selectionTouched: false,
        generation: state.generation + 1, scrollTop: 0, scrollRevision: state.scrollRevision + 1,
      };
    }
    case "select":
      return {
        ...state, selectionTouched: true,
        selectedIndex: clampIndex(
          typeof event.index === "function" ? event.index(state.selectedIndex) : event.index,
          state.items.length,
        ),
      };
    case "results": {
      if (event.generation !== state.generation) return state;
      // Keep matching rows from unfinished sources; a completed source replaces its old rows,
      // even when it returns nothing or fails. New items always own their action payloads.
      const retained = state.items.filter((item) => event.pendingProviderIds?.includes(item.providerId));
      const selectedId = state.items[state.selectedIndex]?.id;
      let items = event.pendingProviderIds
        ? (state.view === "root" ? rankPaletteResults : rankCommands)([...new Map([...retained, ...event.items].map((item) => [item.id, item])).values()], state.query, event.aliases, selectedId)
        : event.items;
      if (event.pendingProviderIds && items.length > 40) {
        const selected = items.find((item) => item.id === selectedId);
        items = items.slice(0, 40);
        if ((state.selectionTouched || state.query.trim()) && selected && !items.some((item) => item.id === selectedId)) {
          items[39] = selected;
        }
      }
      const index = items.findIndex((item) => item.id === selectedId);
      return {
        ...state, items, pending: false,
        // A late source must not replace the Enter target the user is already seeing.
        // Editing the query explicitly chooses the best match again.
        selectedIndex: index >= 0 && (state.selectionTouched || (state.query.trim() && selectedId !== "files:search-broader"))
          ? index : state.selectionTouched ? clampIndex(state.selectedIndex, items.length) : 0,
      };
    }
    case "clipboard":
      if (state.view === "clipboard") return state;
      return {
        ...state, view: "clipboard", query: "", items: [], selectedIndex: 0, pending: true, selectionTouched: false,
        generation: state.generation + 1, scrollTop: 0, scrollRevision: state.scrollRevision + 1,
        parent: {
          query: state.query, items: state.items, selectedIndex: state.selectedIndex,
          scrollTop: event.scrollTop,
        },
      };
    case "back": {
      if (state.view === "root") return state;
      const parent = state.parent;
      return {
        ...state, view: "root", query: parent?.query ?? "", items: parent?.items ?? [],
        selectedIndex: parent?.selectedIndex ?? 0, pending: !parent, selectionTouched: true,
        generation: state.generation + 1, scrollTop: parent?.scrollTop ?? 0,
        scrollRevision: state.scrollRevision + 1, parent: undefined,
      };
    }
    case "reset":
      return {
        ...initialNavigation(), generation: state.generation + 1, pending: true,
        scrollRevision: state.scrollRevision + 1,
      };
  }
}

export type EscapeAction = "recorder" | "settings" | "actions" | "clear" | "back" | "hide";

export function escapeAction(context: {
  recording: boolean;
  settings: boolean;
  actions: boolean;
  query: string;
  view: PaletteView;
}): EscapeAction {
  if (context.recording) return "recorder";
  if (context.settings) return "settings";
  if (context.actions) return "actions";
  if (context.query) return "clear";
  return context.view === "root" ? "hide" : "back";
}
