import type { CommandItem } from "@prism/command-core";

/** Root results show identifying context, not every provider's descriptive text. */
export function resultSubtitle(item: CommandItem): string | undefined {
  if (item.kind === "application" || item.kind === "setting" || item.providerId === "prism") return undefined;
  if (!item.subtitle) return undefined;
  if (item.kind === "file" || item.data?.entryKind === "path") {
    const path = item.subtitle.replace(/\\/g, "/")
      .replace(/^(?:[A-Za-z]:)?\/(?:Users|home)\/[^/]+(?:\/|$)/, "")
      .replace(/^~\//, "");
    const folders = path.split("/").filter(Boolean).slice(0, -1);
    return folders.slice(-2).join(" / ") || undefined;
  }
  if (item.data?.entryKind === "link") {
    try { return new URL(item.subtitle).hostname; }
    catch { return undefined; }
  }
  return item.subtitle;
}
