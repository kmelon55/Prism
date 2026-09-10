import type {
  CommandCatalogDefinition,
  CommandDefinition,
  CommandItem,
  CommandProvider,
} from "./types";

function requireIdentifier(value: string, description: string): void {
  if (!value.trim()) {
    throw new Error(`${description} must not be empty.`);
  }
}

function validateCatalog(catalog: CommandCatalogDefinition): void {
  requireIdentifier(catalog.id, "Provider id");
  requireIdentifier(catalog.label, "Provider label");

  const commandIds = new Set<string>();
  for (const command of catalog.commands) {
    requireIdentifier(command.id, "Command id");
    if (commandIds.has(command.id)) {
      throw new Error(`Duplicate command id: ${command.id}`);
    }
    commandIds.add(command.id);

    const actionIds = new Set<string>();
    for (const action of command.actions) {
      requireIdentifier(action.id, `Action id for ${command.id}`);
      if (actionIds.has(action.id)) {
        throw new Error(`Duplicate action id for ${command.id}: ${action.id}`);
      }
      actionIds.add(action.id);
    }
  }
}

function cloneDefinition(definition: CommandDefinition): CommandDefinition {
  return {
    ...definition,
    keywords: definition.keywords ? [...definition.keywords] : undefined,
    actions: definition.actions.map((action) => ({
      ...action,
      shortcut: action.shortcut ? [...action.shortcut] : undefined,
    })),
    detail: definition.detail
      ? {
          ...definition.detail,
          metadata: definition.detail.metadata?.map((entry) => ({ ...entry })),
        }
      : undefined,
    management: { ...definition.management },
    data: definition.data ? { ...definition.data } : undefined,
  };
}

function materializeCommand(providerId: string, definition: CommandDefinition): CommandItem {
  return { ...cloneDefinition(definition), providerId };
}

/**
 * Creates a provider for commands declared up front by the host or an extension.
 * Search ranking remains centralized in `searchProviders`.
 */
export function createCatalogProvider(catalog: CommandCatalogDefinition): CommandProvider {
  validateCatalog(catalog);
  const commands = catalog.commands.map(cloneDefinition);

  return {
    id: catalog.id,
    label: catalog.label,
    async search(_query, signal) {
      if (signal.aborted) return [];
      return commands.map((command) => materializeCommand(catalog.id, command));
    },
  };
}
