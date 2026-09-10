import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import type { CommandItem, CommandProvider } from "@prism/command-core";

export const webProviderId = "web";

export const webActionIds = {
  openUrl: "open-web-url",
  search: "search-web",
} as const;

const webSearchPrefix = "web ";
const maximumRendererInputBytes = 2_048;
const controlCharacterPattern = /[\u0000-\u001f\u007f-\u009f]/u;

export type WebIntent =
  | { kind: "url"; url: string }
  | { kind: "search"; query: string };

export interface WebActionResult {
  url: string;
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function isExplicitHttpUrl(value: string): boolean {
  return (
    /^https?:\/\//iu.test(value) &&
    !/\s/u.test(value) &&
    !controlCharacterPattern.test(value)
  );
}

/**
 * Recognizes only deliberate web intents. URL parsing and all security checks
 * remain authoritative in the Rust command before an opener is invoked.
 */
export function detectWebIntent(input: string): WebIntent | undefined {
  if (controlCharacterPattern.test(input) || byteLength(input) > maximumRendererInputBytes) {
    return undefined;
  }
  const value = input.trim();
  if (!value) return undefined;

  if (isExplicitHttpUrl(value)) return { kind: "url", url: value };

  if (value.toLowerCase().startsWith(webSearchPrefix)) {
    const query = value.slice(webSearchPrefix.length).trim();
    if (query && !controlCharacterPattern.test(query)) return { kind: "search", query };
  }

  return undefined;
}

function boundedLabel(value: string, maximumLength = 88): string {
  if (value.length <= maximumLength) return value;
  return `${value.slice(0, maximumLength - 1)}…`;
}

function stableIntentId(intent: WebIntent): string {
  const value = intent.kind === "url" ? intent.url : intent.query;
  let hash = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return `web:${intent.kind}:${(hash >>> 0).toString(36)}`;
}

function commandForIntent(intent: WebIntent): CommandItem {
  if (intent.kind === "url") {
    return {
      id: stableIntentId(intent),
      providerId: webProviderId,
      title: t("Open {0}", {"0": boundedLabel(intent.url)}),
      subtitle: t("Open this HTTP(S) URL in the default browser"),
      section: t("Web"),
      kind: "command",
      keywords: ["browser", "open", "url", "web"],
      icon: "globe",
      accent: "cyan",
      detail: {
        eyebrow: "Web URL",
        title: boundedLabel(intent.url, 120),
        description:
          t("Prism's native core validates the address before passing it to the platform browser opener."),
        metadata: [
          { label: t("Allowed protocols"), value: "HTTP · HTTPS" },
          { label: t("Opens with"), value: "Default browser" },
        ],
      },
      data: { webIntent: intent.kind, url: intent.url },
      actions: [
        {
          id: webActionIds.openUrl,
          title: t("Open in default browser"),
          shortcut: ["↵"],
          style: "accent",
        },
      ],
    };
  }

  return {
    id: stableIntentId(intent),
    providerId: webProviderId,
    title: `Search the web for “${boundedLabel(intent.query)}”`,
    subtitle: t("Explicit web search"),
    section: t("Web"),
    kind: "command",
    keywords: ["browser", "find", "search", "web"],
    icon: "globe",
    accent: "blue",
    detail: {
      eyebrow: t("Web search"),
      title: boundedLabel(intent.query, 120),
      description:
        t("The native core encodes this query into a fixed HTTPS search address before opening it."),
      metadata: [
        { label: t("Trigger"), value: "web <query>" },
        { label: t("Opens with"), value: "Default browser" },
      ],
    },
    data: { webIntent: intent.kind, query: intent.query },
    actions: [
      {
        id: webActionIds.search,
        title: t("Search in default browser"),
        shortcut: ["↵"],
        style: "accent",
      },
    ],
  };
}

export const webProvider: CommandProvider = {
  id: webProviderId,
  get label() { return t("Web"); },
  async search(query, signal) {
    if (signal.aborted) return [];
    const intent = detectWebIntent(query);
    return intent ? [{ ...commandForIntent(intent), matchedQuery: query.trim() }] : [];
  },
};

export async function runWebAction(
  actionId: string,
  data: Record<string, unknown> | undefined,
): Promise<WebActionResult> {
  if (actionId === webActionIds.openUrl) {
    if (typeof data?.url !== "string") throw new Error("The web URL is missing.");
    return invoke<WebActionResult>("open_web_url", { url: data.url });
  }
  if (actionId === webActionIds.search) {
    if (typeof data?.query !== "string") throw new Error("The web search query is missing.");
    return invoke<WebActionResult>("search_web", { query: data.query });
  }
  throw new Error(`Unknown web action: ${actionId}`);
}
