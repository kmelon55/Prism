import { expect, it } from "vitest";
import { noteForEditing, markdownTitle } from "./noteMarkdown";
import { noteForStorage } from "./noteAutosave";
import type { LibraryEntry } from "../providers/library";

it("preserves a legacy separate title once and leaves Markdown source untouched on reopen", () => {
  const note: LibraryEntry = { id: "legacy", kind: "note", title: "Meeting", value: "- [x] Ship\n\n```ts\nrun();\n```" };
  const document = noteForEditing(note);
  expect(document.value).toBe(`# Meeting\n\n${note.value}`);
  expect(noteForEditing(noteForStorage(document, "New note"))).toEqual(document);
  const renamed = noteForStorage({ ...document, title: "", value: document.value.replace("Meeting", "Today") }, "New note");
  expect(renamed.title).toBe("Today");
  expect(noteForEditing(renamed).value).toBe(renamed.value);
});

it("derives the first nonempty heading without inserting fallback titles into cleared notes", () => {
  expect(markdownTitle("\n## 한국어 제목 ##\n본문")).toBe("한국어 제목");
  expect(markdownTitle("# " + "🚀".repeat(80))).toBe("🚀".repeat(75));
  for (const title of ["New note", "새 노트"]) {
    expect(noteForEditing({ id: "empty", kind: "note", title, value: "" }).value).toBe("");
  }
});
