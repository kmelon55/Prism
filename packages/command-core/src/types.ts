export type CommandKind =
  | "application"
  | "command"
  | "file"
  | "setting"
  | "extension";

export type CommandActionStyle = "default" | "accent" | "danger";

export interface CommandAction {
  id: string;
  title: string;
  hint?: string;
  shortcut?: string[];
  style?: CommandActionStyle;
}

export type CommandSource = "built-in" | "extension";

export interface CommandManagement {
  readonly source: CommandSource;
  readonly canConfigure: boolean;
  readonly canDisable: boolean;
  readonly canRemove: boolean;
}

export interface CommandItem {
  id: string;
  providerId: string;
  title: string;
  subtitle?: string;
  section: string;
  kind: CommandKind;
  keywords?: string[];
  /** Provider-maintained names; user aliases are separate and have higher priority. */
  searchAliases?: readonly string[];
  icon?: string;
  iconUrl?: string;
  iconTarget?: string;
  accent?: string;
  rankingBoost?: number;
  /** User-defined favorite order; only dominates ranking for an empty query. */
  favoriteOrder?: number;
  /** Exact query recognized by an intent provider; never reuse this result for another query. */
  matchedQuery?: string;
  /** Structured instant result; renderers must not parse display titles to build a result view. */
  answer?: {
    kind: "calculation" | "currency" | "unit";
    input: string;
    inputUnit?: string;
    value: string;
    unit?: string;
    context?: string;
    note?: string;
    stale?: boolean;
  };
  detail?: {
    eyebrow?: string;
    title: string;
    description?: string;
    metadata?: Array<{ label: string; value: string }>;
  };
  actions: CommandAction[];
  management?: CommandManagement;
  data?: Record<string, unknown>;
}

export type CommandDefinition = Omit<CommandItem, "providerId" | "management"> & {
  management: CommandManagement;
};

export interface CommandCatalogDefinition {
  id: string;
  label: string;
  commands: readonly CommandDefinition[];
}

export interface CommandProvider {
  id: string;
  label: string;
  /** Bounded source deadline; network sources may take longer than local catalogs. */
  timeoutMs?: number;
  search(query: string, signal: AbortSignal): Promise<CommandItem[]>;
}

export interface ProviderFailure {
  providerId: string;
  providerLabel: string;
  message: string;
}

export interface SearchResponse {
  items: CommandItem[];
  failures: ProviderFailure[];
}

/** User-owned search aliases keyed by a provider command's stable id. */
export type CommandAliasMap = Readonly<
  Record<CommandItem["id"], readonly string[] | undefined>
>;
