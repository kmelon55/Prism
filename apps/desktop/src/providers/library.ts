import { t } from "../i18n";
import { fileIconName } from "../fileIcons";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  rankCommands,
  type CommandItem,
  type CommandProvider,
} from "@prism/command-core";
import {
  getNativeApplication,
  nativeApplicationItem,
  isTauriRuntime,
} from "./native";
export interface LibraryEntry {
  id: string;
  kind: "link" | "path" | "snippet";
  title: string;
  value: string;
  keyword?: string;
}
export interface Favorite {
  id: string;
  title: string;
}
export interface FileRoot {
  id: string;
  path: string;
}
export interface LibraryData {
  entries: LibraryEntry[];
  roots: FileRoot[];
  favorites: Favorite[];
}
export interface FileHit {
  id: string;
  name: string;
  path: string;
  isDirectory: boolean;
}
export interface FileResults {
  items: FileHit[];
  total: number;
  limited: boolean;
  indexing?: boolean;
  error?: string | null;
}
export const emptyLibrary: LibraryData = {
  entries: [],
  roots: [],
  favorites: [],
};
export const loadLibrary = () => invoke<LibraryData>("library_load");
export const watchLibrary = (callback: () => void) =>
  isTauriRuntime()
    ? listen("prism:library-changed", callback)
    : Promise.resolve(() => {});
export const watchFileIndex = (callback: () => void) =>
  isTauriRuntime()
    ? listen("prism:file-index-changed", callback)
    : Promise.resolve(() => {});
export type FileType = "all" | "folder" | "text" | "image" | "document";
export interface FilePreview {
  id: string;
  name: string;
  path: string;
  isDirectory: boolean;
  extension: string;
  size: number;
  modifiedAt: number | null;
  kind: "text" | "image" | "directory" | "unsupported";
  text: string | null;
  imageDataUrl: string | null;
  truncated: boolean;
}
export const searchFiles = (
  query: string,
  offset = 0,
  limit = 40,
  fileType: FileType = "all",
  includeSystem = false,
) =>
  invoke<FileResults>("library_search_files", {
    query,
    offset,
    limit,
    fileType,
    ...(includeSystem ? { includeSystem: true } : {}),
  });
export const previewFile = (id: string) =>
  invoke<FilePreview>("library_preview_file", { id });
export function entryItem(entry: LibraryEntry): CommandItem {
  const snippet = entry.kind === "snippet";
  return {
    id: `library:${entry.id}`,
    providerId: "library",
    title: entry.title,
    subtitle: snippet ? entry.value.slice(0, 140) : entry.value,
    section: snippet ? t("스니펫") : t("저장된 링크"),
    kind: "command",
    icon: snippet
      ? "clipboard"
      : entry.kind === "path"
        ? "folder-open"
        : "globe",
    keywords: [snippet ? "snippet 스니펫 문구" : "quicklink 링크 바로가기"],
    searchAliases: snippet && entry.keyword ? [entry.keyword] : undefined,
    data: { entryId: entry.id, entryKind: entry.kind },
    actions: [
      {
        id: snippet ? "library-copy" : "library-open",
        title: snippet ? t("복사") : t("열기"),
      },
      ...(snippet
        ? [{ id: "library-paste", title: t("붙여넣기") }]
        : [{ id: "library-copy", title: t("주소 복사") }]),
      { id: "library-edit", title: t("편집") },
    ],
  };
}
export function fileItem(file: FileHit): CommandItem {
  return {
    id: `file:${file.id}`,
    providerId: "files",
    title: file.name,
    subtitle: file.path,
    section: t("파일"),
    kind: "file",
    icon: fileIconName(file.name, file.isDirectory),
    data: { fileId: file.id },
    actions: [
      { id: "file-open", title: t("열기") },
      { id: "file-reveal", title: t("Finder에서 보기") },
      { id: "file-copy", title: t("경로 복사") },
    ],
  };
}
export const fileProvider: CommandProvider = {
  id: "files",
  get label() {
    return t("파일");
  },
  timeoutMs: 5000,
  async search(query, signal) {
    if (!query.trim() || signal.aborted) return [];
    const data = await searchFiles(query, 0, 8);
    if (signal.aborted) return [];
    return [...data.items.map(fileItem), {
      id: "files:search-broader",
      providerId: "files",
      title: t("더 넓게 검색"),
      subtitle: query.trim(),
      section: t("파일"),
      kind: "command" as const,
      icon: "search",
      data: { query: query.trim() },
      actions: [{ id: "files-search-broader", title: t("더 넓게 검색") }],
    }];
  },
};
export function libraryProvider(
  data: LibraryData,
  definitions: CommandItem[],
): CommandProvider {
  return {
    id: "library",
    label: t("보관함"),
    async search(query, signal) {
      const entries = data.entries.map(entryItem);
      if (!query.trim()) {
        for (const favorite of data.favorites) {
          if (signal.aborted) break;
          if (entries.some((e) => e.id === favorite.id)) continue;
          if (favorite.id.startsWith("native:")) {
            const app = await getNativeApplication(favorite.id.slice(7));
            if (app) entries.push(nativeApplicationItem(app));
          } else {
            const item = definitions.find((d) => d.id === favorite.id);
            if (item) entries.push(item);
          }
        }
      }
      const ranked = entries.map((item) => {
        const order = data.favorites.findIndex((f) => f.id === item.id);
        return { ...item, ...(order >= 0 ? { favoriteOrder: order } : {}) };
      });
      return rankCommands(ranked, query).slice(0, 50);
    },
  };
}
