import { describe, expect, it } from "vitest";
import type { CommandItem } from "@prism/command-core";
import { resultSubtitle } from "./resultPresentation";

const item: CommandItem = { id: "fixture", providerId: "files", title: "Notes.md", section: "Files", kind: "file", actions: [] };

describe("root result information hierarchy", () => {
  it.each([
    "/Users/person/Documents/Prism/Notes.md",
    "/home/person/Documents/Prism/Notes.md",
    "C:\\Users\\person\\Documents\\Prism\\Notes.md",
  ])("shows short file context without repeating the filename: %s", (subtitle) => {
    expect(resultSubtitle({ ...item, subtitle })).toBe("Documents / Prism");
  });

  it("never exposes a restored application subtitle in the root list", () => {
    expect(resultSubtitle({ ...item, kind: "application", subtitle: "/Applications/Paper.app" })).toBeUndefined();
  });

  it("omits built-in descriptions but preserves useful snippet content", () => {
    expect(resultSubtitle({ ...item, kind: "command", providerId: "prism", subtitle: "Long implementation description" })).toBeUndefined();
    expect(resultSubtitle({ ...item, kind: "command", providerId: "library", data: { entryKind: "snippet" }, subtitle: "Meeting notes" })).toBe("Meeting notes");
  });

  it("shows the link destination without its path or query", () => {
    expect(resultSubtitle({ ...item, kind: "command", data: { entryKind: "link" }, subtitle: "https://example.com/search?q={query}" })).toBe("example.com");
  });
});
