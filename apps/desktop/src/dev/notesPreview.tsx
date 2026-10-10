// Development-only UI preview. Data belongs to this browser origin, never the native library.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { mockIPC } from "@tauri-apps/api/mocks";
import { LibraryPanel } from "../LibraryPanel";
import { emptyLibrary, type LibraryData, type LibraryEntry } from "../providers/library";
import "../styles.css";
import "../settings/launcherImprovements.css";
import "../surfaces.css";
import "../interaction/prismReflections.css";

if (!import.meta.env.DEV) throw new Error("This preview is only available on the development server.");

const storageKey = "prism:notes-browser-preview:v1";
const read = (): LibraryData => JSON.parse(localStorage.getItem(storageKey) ?? JSON.stringify(emptyLibrary));
mockIPC(async (command, payload) => {
  const args = payload as { entry?: LibraryEntry; id?: string; action?: string };
  const data = read();
  switch (command) {
    case "library_load": return data;
    case "library_save_entry": {
      const entry = args.entry!;
      if (new TextEncoder().encode(entry.value).length > 128 * 1024) throw "내용은 최대 128 KB입니다.";
      data.entries = [entry, ...data.entries.filter(item => item.id !== entry.id)];
      localStorage.setItem(storageKey, JSON.stringify(data));
      return;
    }
    case "library_delete_entry":
      data.entries = data.entries.filter(entry => entry.id !== args.id);
      localStorage.setItem(storageKey, JSON.stringify(data));
      return;
    case "library_entry_action": {
      const entry = data.entries.find(entry => entry.id === args.id);
      if (!entry) throw "항목이 삭제되었습니다.";
      if (args.action !== "copy") throw "이 동작은 데스크톱 앱에서 사용할 수 있습니다.";
      await navigator.clipboard.writeText(entry.value);
      return;
    }
    case "library_search_files": return { items: [], total: 0, limited: false };
    default: throw "이 동작은 데스크톱 앱에서 사용할 수 있습니다.";
  }
}, { shouldMockEvents: true });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <main className="prism-shell browser-preview ai-expanded">
      <LibraryPanel nativeRuntime initialTab="notes" onChange={() => {}}
        onClose={() => window.location.assign("/")} />
    </main>
  </StrictMode>,
);
