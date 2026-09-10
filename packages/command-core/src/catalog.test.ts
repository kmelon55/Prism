import { describe, expect, it } from "vitest";
import { createCatalogProvider } from "./catalog";
import type { CommandCatalogDefinition, CommandDefinition } from "./types";

const builtInManagement = {
  source: "built-in",
  canConfigure: false,
  canDisable: false,
  canRemove: false,
} as const;

const command = (id = "prism:preferences"): CommandDefinition => ({
  id,
  title: "Open Prism preferences",
  section: "Prism",
  kind: "setting",
  keywords: ["settings"],
  detail: {
    title: "Preferences",
    metadata: [{ label: "Owner", value: "Prism" }],
  },
  actions: [{ id: "open-settings", title: "Open preferences", shortcut: ["Enter"] }],
  management: builtInManagement,
  data: { surface: "preferences" },
});

const catalog = (commands: readonly CommandDefinition[]): CommandCatalogDefinition => ({
  id: "prism",
  label: "Prism",
  commands,
});

describe("createCatalogProvider", () => {
  it("materializes stable definitions with provider and management metadata", async () => {
    const definition = command();
    const provider = createCatalogProvider(catalog([definition]));
    definition.title = "Changed after registration";
    const signal = new AbortController().signal;
    const first = await provider.search("preferences", signal);
    const second = await provider.search("", signal);

    expect(first[0]).toMatchObject({
      id: "prism:preferences",
      providerId: "prism",
      title: "Open Prism preferences",
      management: builtInManagement,
    });
    expect(first[0]).not.toBe(second[0]);
    expect(first[0].actions).not.toBe(second[0].actions);
    expect(first[0].management).not.toBe(second[0].management);
  });

  it("returns no catalog items after cancellation", async () => {
    const controller = new AbortController();
    controller.abort();
    const provider = createCatalogProvider(catalog([command()]));

    await expect(provider.search("", controller.signal)).resolves.toEqual([]);
  });

  it("rejects duplicate command ids", () => {
    expect(() => createCatalogProvider(catalog([command(), command()]))).toThrow(
      "Duplicate command id: prism:preferences",
    );
  });

  it("rejects duplicate action ids within a command", () => {
    const definition = command();
    definition.actions.push({ id: "open-settings", title: "Open again" });

    expect(() => createCatalogProvider(catalog([definition]))).toThrow(
      "Duplicate action id for prism:preferences: open-settings",
    );
  });
});
