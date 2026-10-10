import type { LibraryEntry } from "../providers/library";
import { markdownTitle } from "./noteMarkdown";

export type NoteSaveStatus = "idle" | "saving" | "saved" | "error";

/** Keep body-only and title-only drafts valid without rewriting the editor's text. */
export function noteForStorage(note: LibraryEntry, fallbackTitle: string): LibraryEntry {
  const derivedTitle = markdownTitle(note.value) || fallbackTitle;
  return { ...note, title: note.title.trim() || [...derivedTitle].slice(0, 75).join("") };
}

/** Serialize writes and coalesce edits made while a write is in flight. */
export function createNoteAutosave(
  initial: LibraryEntry,
  persist: (note: LibraryEntry) => Promise<void>,
  onStatus: (status: NoteSaveStatus, error?: unknown) => void,
) {
  let latest = initial;
  let saved = JSON.stringify(initial);
  let running: Promise<boolean> | undefined;

  function flush(): Promise<boolean> {
    if (running) return running;
    if (JSON.stringify(latest) === saved) {
      onStatus("saved");
      return Promise.resolve(true);
    }
    // Assign the promise before calling external callbacks or starting persistence.
    running = Promise.resolve().then(async () => {
      onStatus("saving");
      while (JSON.stringify(latest) !== saved) {
        const snapshot = latest;
        try {
          await persist(snapshot);
          saved = JSON.stringify(snapshot);
        } catch (error) {
          onStatus("error", error);
          return false;
        }
      }
      onStatus("saved");
      return true;
    }).finally(() => { running = undefined; });
    return running;
  }

  return {
    update(note: LibraryEntry) {
      latest = note;
      void flush();
    },
    flush,
  };
}
