import { describe, expect, it } from "vitest";
import type { CommandItem } from "@prism/command-core";
import { escapeAction, initialNavigation, navigate, rankPaletteResults } from "./navigation";

const items = ["first", "clipboard", "third"].map((id): CommandItem => ({
  id, title: id, providerId: "fixture", section: "Test", kind: "command", actions: [],
}));

describe("palette navigation", () => {
  it("keeps applications and commands above even exact filename matches", () => {
    const file: CommandItem = { ...items[0], id: "file", title: "clip", kind: "file", providerId: "files" };
    const command = { ...items[1], title: "Clipboard History" };
    const application: CommandItem = { ...items[0], id: "app", title: "Clip Studio", kind: "application" };
    const ranked = rankPaletteResults([file, command, application], "clip");
    expect(ranked.at(-1)?.id).toBe("file");
    let state = navigate(initialNavigation(ranked), { type: "query", query: "clip" });
    expect(state.items.at(-1)?.id).toBe("file");
    state = navigate(state, { type: "results", generation: state.generation, items: [file, command, application], pendingProviderIds: [] });
    expect(state.items.at(-1)?.id).toBe("file");
  });

  it("fills the display window with applications before file candidates", () => {
    const apps = Array.from({ length: 60 }, (_, i): CommandItem => ({
      ...items[0], id: `app${i}`, title: `Report Tool ${i}`, kind: "application", rankingBoost: 72,
    }));
    const file: CommandItem = { ...items[0], id: "report", title: "Report", kind: "file" };
    let state = navigate(initialNavigation(), { type: "query", query: "report" });
    state = navigate(state, { type: "results", generation: state.generation, items: [...apps, file], pendingProviderIds: [] });
    expect(state.items).toHaveLength(40);
    expect(state.items.every(({ kind }) => kind === "application")).toBe(true);
  });

  it("limits supplementary file matches and favors apps within the same match tier", () => {
    const files = Array.from({ length: 30 }, (_, i): CommandItem => ({
      ...items[0], id: `file${i}`, title: `Report ${i}`, kind: "file", rankingBoost: 72,
    }));
    const app: CommandItem = { ...items[0], id: "app", title: "Report Viewer", kind: "application" };
    const exact: CommandItem = { ...files[0], id: "exact", title: "Report" };
    const ranked = rankPaletteResults([...files, app, exact], "report");
    expect(ranked.slice(0, 2).map(({ id }) => id)).toEqual(["app", "exact"]);
    expect(ranked.filter(({ kind }) => kind === "file")).toHaveLength(9);
  });

  it("preserves keyboard selection when late matches push it past the forty-row cutoff", () => {
    const selected = { ...items[0], title: "Report Viewer" };
    let state = navigate(initialNavigation([selected]), { type: "query", query: "report" });
    state = navigate(state, { type: "select", index: 0 });
    const late = Array.from({ length: 45 }, (_, i) => ({ ...items[0], id: `late${i}`, title: "Report" }));
    state = navigate(state, { type: "results", generation: state.generation, items: [...late, selected], pendingProviderIds: [] });
    expect(state.items).toHaveLength(40);
    expect(state.items[state.selectedIndex].id).toBe(selected.id);
    expect(state.items[0].id).toBe("late0");
  });

  it("retains a selected file beyond the supplementary quota but removes it when its source drops it", () => {
    const selected: CommandItem = { ...items[0], id: "selected-file", title: "Report Z", kind: "file", providerId: "files" };
    let state = navigate(initialNavigation([selected]), { type: "query", query: "report" });
    state = navigate(state, { type: "select", index: 0 });
    const late = Array.from({ length: 12 }, (_, i): CommandItem => ({ ...selected, id: `late-file${i}`, title: "Report A", rankingBoost: 72 }));
    state = navigate(state, { type: "results", generation: state.generation, items: [...late, selected], pendingProviderIds: [] });
    expect(state.items).toHaveLength(9);
    expect(state.items[state.selectedIndex].id).toBe(selected.id);
    state = navigate(state, { type: "results", generation: state.generation, items: late, pendingProviderIds: [] });
    expect(state.items.some(({ id }) => id === selected.id)).toBe(false);
    expect(state.items).toHaveLength(8);
  });

  it("preserves the visible automatic selection when a better match arrives later", () => {
    const command = { ...items[1], title: "Clipboard History" };
    const late = { ...items[0], title: "clip" };
    let state = navigate(initialNavigation([command]), { type: "query", query: "clip" });
    expect(state.selectionTouched).toBe(false);
    state = navigate(state, { type: "results", generation: state.generation, items: [late, command], pendingProviderIds: [] });
    expect(state.items[0].id).toBe(late.id);
    expect(state.items[state.selectedIndex].id).toBe(command.id);
    state = navigate(state, { type: "query", query: "cli" });
    expect(state.selectedIndex).toBe(0);
  });

  it("retains only current-query matches, including aliases, and drops old instant answers", () => {
    const answer = { ...items[0], id: "answer", matchedQuery: "4+4" };
    const state = navigate(initialNavigation([...items, answer]), {
      type: "query", query: "notes", aliases: { clipboard: ["notes"] },
    });
    expect(state.items.map(({ id }) => id)).toEqual(["clipboard"]);
    expect(state.pending).toBe(true);
  });

  it("keeps matching rows until their source finishes and removes them on an empty completion", () => {
    let state = navigate(initialNavigation(items), { type: "query", query: "first" });
    state = navigate(state, { type: "results", generation: state.generation, items: [], pendingProviderIds: ["fixture"] });
    expect(state.items).toEqual([items[0]]);
    state = navigate(state, { type: "results", generation: state.generation, items: [], pendingProviderIds: [] });
    expect(state.items).toEqual([]);
  });

  it("restores a parent's query, selected ID and scroll position after scoped search", () => {
    let state = navigate(initialNavigation(), { type: "query", query: "clip" });
    state = navigate(state, { type: "results", generation: state.generation, items });
    state = navigate(state, { type: "select", index: 1 });
    state = navigate(state, { type: "clipboard", scrollTop: 144 });
    state = navigate(state, { type: "query", query: "copied text" });
    state = navigate(state, { type: "back" });
    expect(state.query).toBe("clip");
    expect(state.items[state.selectedIndex].id).toBe("clipboard");
    expect(state.scrollTop).toBe(144);
    expect(state.view).toBe("root");
    expect(state.parent).toBeUndefined();
  });

  it("does not overwrite a parent when a scoped hotkey repeats", () => {
    const scoped = navigate(initialNavigation(items), { type: "clipboard", scrollTop: 88 });
    expect(navigate(scoped, { type: "clipboard", scrollTop: 0 })).toBe(scoped);
  });

  it("rejects stale results even when a query is changed back to the same text", () => {
    const first = navigate(initialNavigation(), { type: "query", query: "a" });
    const second = navigate(first, { type: "query", query: "b" });
    const third = navigate(second, { type: "query", query: "a" });
    expect(navigate(third, { type: "results", generation: first.generation, items })).toBe(third);
    expect(third.items).toEqual([]);
    expect(third.pending).toBe(true);
  });

  it("preserves selection by ID on refresh, then falls back to the nearest surviving row", () => {
    let state = navigate(initialNavigation(items), { type: "select", index: 1 });
    state = navigate(state, { type: "results", generation: 0, items: [items[2], items[0], items[1]] });
    expect(state.selectedIndex).toBe(2);
    state = navigate(state, { type: "results", generation: 0, items: [items[2], items[0]] });
    expect(state.selectedIndex).toBe(1);
  });

  it("clamps arrow navigation at both ends and handles empty results", () => {
    let state = navigate(initialNavigation(items), { type: "select", index: -1 });
    expect(state.selectedIndex).toBe(0);
    state = navigate(state, { type: "select", index: 100 });
    expect(state.selectedIndex).toBe(2);
    state = navigate(state, { type: "results", generation: 0, items: [] });
    expect(state.selectedIndex).toBe(0);
  });

  it("drops transient history on hide/reset and invalidates in-flight work", () => {
    const scoped = navigate(initialNavigation(items), { type: "clipboard", scrollTop: 30 });
    const reset = navigate(scoped, { type: "reset" });
    expect(reset.parent).toBeUndefined();
    expect(reset.view).toBe("root");
    expect(reset.query).toBe("");
    expect(navigate(reset, { type: "results", generation: scoped.generation, items })).toBe(reset);
  });
});

describe("Escape priority", () => {
  const context = { recording: false, settings: false, actions: false, query: "", view: "root" as const };
  it("closes overlays before clearing queries and clears before leaving a scope", () => {
    expect(escapeAction({ ...context, actions: true, query: "clip" })).toBe("actions");
    expect(escapeAction({ ...context, view: "clipboard", query: "word" })).toBe("clear");
    expect(escapeAction({ ...context, view: "clipboard" })).toBe("back");
    expect(escapeAction(context)).toBe("hide");
  });
  it("lets settings own confirmations and lets a recorder cancel first", () => {
    expect(escapeAction({ ...context, settings: true, query: "word" })).toBe("settings");
    expect(escapeAction({ ...context, settings: true, recording: true })).toBe("recorder");
  });
});
