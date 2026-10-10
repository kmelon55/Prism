import type { LibraryEntry } from "../providers/library";

export function markdownTitle(value: string): string {
  const firstLine = value.split(/\r?\n/).find(line => line.trim())?.trim() ?? "";
  return [...firstLine.replace(/^#{1,6}\s+/, "").replace(/\s+#+$/, "")].slice(0, 75).join("");
}

/** Preserve titles written in the old separate title field as Markdown content. */
export function noteForEditing(entry: LibraryEntry): LibraryEntry {
  if (entry.kind !== "note") return entry;
  const title = entry.title.trim();
  const firstLine = entry.value.split(/\r?\n/).find(line => line.trim())?.trim() ?? "";
  const hasSeparateTitle = title && title !== markdownTitle(entry.value) && title !== firstLine
    && !(entry.value === "" && ["New note", "새 노트"].includes(title));
  return { ...entry, value: hasSeparateTitle ? `# ${title}\n\n${entry.value}` : entry.value };
}

export function markdownExcerpt(value: string): string {
  return value.split(/\r?\n/).filter(line => line.trim()).slice(1).join(" ").slice(0, 120);
}
