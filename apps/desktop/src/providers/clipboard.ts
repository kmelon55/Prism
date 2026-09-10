import { invoke } from "@tauri-apps/api/core";
import { emitClipboardHistorySettingChanged, isTauriRuntime } from "./native";

export type ClipboardKind = "text" | "image" | "files";
export type ClipboardTypeFilterValue = "all" | ClipboardKind;
export interface ClipboardPreviewMetadata {
  kind?: ClipboardKind;
  mimeType?: string | null;
  byteSize?: number;
  width?: number | null;
  height?: number | null;
  fileCount?: number;
  available?: boolean | null;
}
export type ClipboardRetentionDays = 1 | 7 | 30 | 90;
export interface ClipboardSettingsState {
  enabled: boolean;
  retentionDays: ClipboardRetentionDays;
  entryCount: number;
  pinnedCount: number;
  capacity: number;
  persistenceError: string | null;
  captureNotice?: string | null;
}
export interface DurableClipboardEntry extends ClipboardPreviewMetadata {
  id: number;
  content: string;
  capturedAt: number;
  pinned: boolean;
}
export function getClipboardHistorySettings(): Promise<ClipboardSettingsState> {
  return invoke("get_clipboard_history_settings");
}
export function setClipboardHistoryRetention(retentionDays: ClipboardRetentionDays): Promise<ClipboardSettingsState> {
  return invoke("set_clipboard_history_retention", { retentionDays });
}
export function setClipboardHistoryEntryPinned(id: number, pinned: boolean): Promise<void> {
  return invoke("set_clipboard_history_entry_pinned", { id, pinned });
}
/** Full original text for selected previews and snippets; search content is only a 500-character preview. */
export function getClipboardHistoryEntryText(id: number): Promise<string> {
  return invoke("get_clipboard_history_entry_text", { id });
}
/** Use this search instead of the legacy mapper when rendering pin actions. */
export async function searchDurableClipboardHistory(query: string, limit = 40, kind: ClipboardTypeFilterValue = "all"): Promise<DurableClipboardEntry[]> {
  const entries = await invoke<Array<{ id: number; text: string; capturedAtMs: number; pinned: boolean } & ClipboardPreviewMetadata>>("search_clipboard_history", { query, limit, kind: kind === "all" ? null : kind });
  return entries.map(({ id, text, capturedAtMs, pinned, ...metadata }) => ({ id, content: text, capturedAt: capturedAtMs, pinned, ...metadata }));
}
export async function notifyClipboardSettingsChanged(settings: ClipboardSettingsState): Promise<void> {
  if (isTauriRuntime()) await emitClipboardHistorySettingChanged(settings.enabled);
}

/** Downscaled selected-image preview; originals remain native and are reused by copy/paste. */
export function getClipboardHistoryEntryPreview(id: number): Promise<string> {
  return invoke("get_clipboard_history_entry_preview", { id });
}
