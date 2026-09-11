import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { commonApplicationAliases, rankCommands, type CommandAliasMap, type CommandItem, type CommandProvider } from "@prism/command-core";

export interface NativeApplication {
  id: string;
  name: string;
  path: string;
  platform: string;
  rankingBoost: number;
}

export interface NativeSettingsNavigationRequest {
  section: "applications" | "ai";
  applicationId?: string;
  applicationName?: string;
}

export interface NativeActionResult {
  usageRecorded: boolean;
}

const iconRequests = new Map<string, Promise<string | undefined>>();
const resolvedIcons = new Map<string, string | null>();
const iconQueue: Array<{
  target: string;
  resolve: (icon: string | undefined) => void;
  generation: number;
}> = [];
let activeIconRequests = 0;
let iconRequestGeneration = 0;
const maximumConcurrentIconRequests = 3;
const maximumResolvedIcons = 256;

export const isTauriRuntime = (): boolean => Boolean(window.__TAURI_INTERNALS__);

export const nativeApplicationCommandId = (applicationId: string): string =>
  `native:${applicationId}`;

/** Resolve only matching aliases, with bounded IPC concurrency and cooperative cancellation. */
export function createApplicationAliasProvider(aliases: CommandAliasMap): CommandProvider {
  return {
    id: "application-aliases",
    label: t("Application aliases"),
    async search(query, signal) {
      if (!query.trim() || signal.aborted) return [];
      const candidates = rankCommands(Object.keys(aliases).filter((id) => id.startsWith("native:")).map((id): CommandItem => ({
        id, title: "", section: "", kind: "application", providerId: "application-aliases", actions: [],
      })), query, aliases).slice(0, 40);
      const resolved: Array<CommandItem | undefined> = new Array(candidates.length);
      let cursor = 0;
      await Promise.all(Array.from({ length: Math.min(4, candidates.length) }, async () => {
        while (!signal.aborted && cursor < candidates.length) {
          const index = cursor++;
          const application = await getNativeApplication(candidates[index].id.slice("native:".length));
          if (application && !signal.aborted) resolved[index] = nativeApplicationItem(application);
        }
      }));
      return resolved.filter((item): item is CommandItem => item !== undefined);
    },
  };
}

function drainIconQueue() {
  while (activeIconRequests < maximumConcurrentIconRequests && iconQueue.length) {
    const next = iconQueue.shift();
    if (!next) return;
    if (next.generation !== iconRequestGeneration) {
      next.resolve(undefined);
      continue;
    }
    activeIconRequests += 1;
    const request = next.target.startsWith("system:")
      ? invoke<string | null>("load_system_icon", { commandId: next.target })
      : invoke<string | null>("load_application_icon", { target: next.target });
    void request
      .then((icon) => {
        if (next.generation === iconRequestGeneration) {
          cacheResolvedIcon(next.target, icon);
          next.resolve(icon ?? undefined);
        } else {
          next.resolve(undefined);
        }
      })
      .catch(() => {
        // A failed IPC call is not evidence that artwork is absent. Allow a later
        // view to retry, for example after the native backend becomes available.
        next.resolve(undefined);
      })
      .finally(() => {
        if (next.generation === iconRequestGeneration) iconRequests.delete(next.target);
        activeIconRequests -= 1;
        drainIconQueue();
      });
  }
}

function cacheResolvedIcon(target: string, icon: string | null) {
  resolvedIcons.delete(target);
  resolvedIcons.set(target, icon);
  while (resolvedIcons.size > maximumResolvedIcons) {
    const oldestTarget = resolvedIcons.keys().next().value;
    if (oldestTarget === undefined) break;
    resolvedIcons.delete(oldestTarget);
  }
}

export function loadNativeIcon(target: string): Promise<string | undefined> {
  if (!isTauriRuntime()) return Promise.resolve(undefined);
  if (resolvedIcons.has(target)) {
    const icon = resolvedIcons.get(target) ?? null;
    cacheResolvedIcon(target, icon);
    return Promise.resolve(icon ?? undefined);
  }
  const cached = iconRequests.get(target);
  if (cached) return cached;

  const request = new Promise<string | undefined>((resolve) => {
    iconQueue.push({ target, resolve, generation: iconRequestGeneration });
    drainIconQueue();
  });
  iconRequests.set(target, request);
  return request;
}

export function getResolvedNativeIcon(target: string): string | null | undefined {
  const icon = resolvedIcons.get(target);
  if (icon !== undefined) cacheResolvedIcon(target, icon);
  return icon;
}

function resetNativeApplicationIconState() {
  iconRequestGeneration += 1;
  iconRequests.clear();
  resolvedIcons.clear();
  iconQueue.splice(0).forEach(({ resolve }) => resolve(undefined));
}

export async function refreshNativeApplicationCatalog(): Promise<number> {
  if (!isTauriRuntime()) return 0;
  return invoke<number>("refresh_application_index");
}

export async function searchNativeApplications(
  query: string,
  limit = 40,
): Promise<NativeApplication[]> {
  if (!isTauriRuntime()) return [];
  return invoke<NativeApplication[]>("search_applications", { query, limit });
}

export async function getNativeApplication(
  applicationId: string,
): Promise<NativeApplication | undefined> {
  if (!isTauriRuntime()) return undefined;
  const application = await invoke<NativeApplication | null>("get_application", {
    applicationId,
  });
  return application ?? undefined;
}

export async function onNativeApplicationIndexUpdated(
  callback: (applicationCount: number) => void,
): Promise<() => void> {
  if (!isTauriRuntime()) return () => undefined;
  return listen<{ applicationCount: number }>("prism:application-index-updated", (event) => {
    callback(event.payload.applicationCount);
  });
}

export async function clearNativeApplicationIconCache(): Promise<void> {
  resetNativeApplicationIconState();
  if (!isTauriRuntime()) return;
  await invoke("clear_application_icon_cache");
}

export async function onNativeApplicationIconCacheCleared(
  callback: () => void,
): Promise<() => void> {
  if (!isTauriRuntime()) return () => undefined;
  return listen("prism:application-icon-cache-cleared", () => {
    resetNativeApplicationIconState();
    callback();
  });
}

export function nativeApplicationItem(application: NativeApplication): CommandItem {
  return {
    id: nativeApplicationCommandId(application.id),
    providerId: "native-applications",
    title: application.name,
    section: t("Applications"),
    kind: "application",
    keywords: ["app", application.platform, application.path],
    searchAliases: commonApplicationAliases(application.name),
    icon: "app-window",
    iconTarget: application.path,
    accent: "mint",
    rankingBoost: application.rankingBoost,
    detail: {
      eyebrow: "Installed application",
      title: application.name,
      description: t("Discovered locally by Prism's Rust core. No catalog data leaves this device."),
      metadata: [
        { label: t("Platform"), value: application.platform },
        { label: t("Location"), value: application.path },
        { label: t("Provider"), value: "Native application index" },
      ],
    },
    data: { applicationId: application.id, target: application.path },
    actions: [
      { id: "launch-native", title: t("열기"), shortcut: ["↵"], style: "accent" },
      { id: "reveal-native", title: t("Reveal application"), shortcut: ["⌘", "R"] },
      { id: "copy-native-path", title: t("Copy path"), shortcut: ["⌘", "C"] },
      { id: "configure-native", title: t("Configure Application"), shortcut: ["⌘", ","] },
    ],
    management: {
      source: "built-in",
      canConfigure: true,
      canDisable: true,
      canRemove: false,
    },
  };
}

export const nativeApplicationProvider: CommandProvider = {
  id: "native-applications",
  get label() { return t("Installed applications"); },
  async search(query, signal) {
    if (!isTauriRuntime() || signal.aborted) return [];
    const applications = await searchNativeApplications(query, query.trim() ? 40 : 24);
    if (signal.aborted) return [];

    return applications.map(nativeApplicationItem);
  },
};

export async function runNativeAction(
  actionId: string,
  applicationId: string,
  target: string,
): Promise<NativeActionResult> {
  if (actionId === "launch-native") {
    return invoke<NativeActionResult>("launch_application", { applicationId, target });
  }
  if (actionId === "reveal-native") {
    return invoke<NativeActionResult>("reveal_application", { applicationId, target });
  }
  throw new Error(`Unknown native action: ${actionId}`);
}

export async function setNativeWindowBlur(strength: number): Promise<void> {
  if (!isTauriRuntime()) return;
  await invoke("set_window_blur", { strength });
}

export interface ClipboardHistoryEntry {
  id: number;
  content: string;
  capturedAt: number;
  pinned?: boolean;
  kind?: "text" | "image" | "files";
  mimeType?: string | null;
  byteSize?: number;
  width?: number | null;
  height?: number | null;
  fileCount?: number;
  available?: boolean | null;
}

interface NativeClipboardHistoryEntry {
  id: number;
  content?: string;
  text?: string;
  capturedAt?: number;
  capturedAtMs?: number;
  pinned?: boolean;
  kind?: "text" | "image" | "files";
  mimeType?: string | null;
  byteSize?: number;
  width?: number | null;
  height?: number | null;
  fileCount?: number;
  available?: boolean | null;
}

export type WindowManagementAction =
  | "maximize-width"
  | "maximize-height"
  | "reasonable-size"
  | "first-fourth"
  | "second-fourth"
  | "third-fourth"
  | "last-fourth"
  | "move-left"
  | "move-right"
  | "move-up"
  | "move-down"
  | "next-display"
  | "previous-display"

  | "left-half"
  | "right-half"
  | "top-half"
  | "bottom-half"
  | "top-left-quarter"
  | "top-right-quarter"
  | "bottom-left-quarter"
  | "bottom-right-quarter"
  | "top-left-sixth"
  | "top-center-sixth"
  | "top-right-sixth"
  | "bottom-left-sixth"
  | "bottom-center-sixth"
  | "bottom-right-sixth"
  | "first-third"
  | "center-third"
  | "last-third"
  | "left-two-thirds"
  | "center-two-thirds"
  | "right-two-thirds"
  | "maximize"
  | "almost-maximize"
  | "center"
  | "restore-previous-layout";

export interface WindowManagementResult {
  action: WindowManagementAction;
  supported: boolean;
  applied: boolean;
  message: string;
}

export interface AccessibilityPermissionStatus {
  supported: boolean;
  granted: boolean;
  canRequest: boolean;
  message: string;
}

export interface CommandShortcut {
  commandId: string;
  accelerator: string;
  registered?: boolean;
  issue?: { code: string; message: string } | null;
}

interface NativeCommandShortcut extends Omit<CommandShortcut, "accelerator"> {
  accelerator?: string;
  shortcut?: string;
}

export interface CommandHotkeyPayload {
  commandId: string;
  background?: boolean;
}

export function openNativeSettingsWindow(): Promise<void> {
  return invoke("open_settings_window");
}

const settingsNavigationStorageKey = "prism:settings-navigation";

export async function openNativeApplicationSettings(
  request: Omit<NativeSettingsNavigationRequest, "section">,
): Promise<void> {
  return openNativeSettingsSection({ section: "applications", ...request });
}

export async function openNativeSettingsSection(navigation: NativeSettingsNavigationRequest): Promise<void> {
  localStorage.setItem(settingsNavigationStorageKey, JSON.stringify(navigation));
  try {
    await openNativeSettingsWindow();
    await emit("prism:settings-navigation", navigation);
  } catch (error) {
    localStorage.removeItem(settingsNavigationStorageKey);
    throw error;
  }
}

export function takePendingNativeSettingsNavigation(): NativeSettingsNavigationRequest | undefined {
  const stored = localStorage.getItem(settingsNavigationStorageKey);
  localStorage.removeItem(settingsNavigationStorageKey);
  if (!stored) return undefined;
  try {
    const request = JSON.parse(stored) as Partial<NativeSettingsNavigationRequest>;
    if (request.section === "ai") return { section: "ai" };
    if (request.section !== "applications") return undefined;
    return {
      section: "applications",
      applicationId: typeof request.applicationId === "string" ? request.applicationId : undefined,
      applicationName: typeof request.applicationName === "string" ? request.applicationName : undefined,
    };
  } catch {
    return undefined;
  }
}

export function onNativeSettingsNavigation(
  callback: (request: NativeSettingsNavigationRequest) => void,
): Promise<() => void> {
  if (!isTauriRuntime()) return Promise.resolve(() => undefined);
  return listen<NativeSettingsNavigationRequest>("prism:settings-navigation", (event) => {
    localStorage.removeItem(settingsNavigationStorageKey);
    callback(event.payload);
  });
}

export function emitScriptRegistryChanged(): Promise<void> {
  if (!isTauriRuntime()) return Promise.resolve();
  return emit("prism:script-registry-changed");
}

export function onScriptRegistryChanged(callback: () => void): Promise<() => void> {
  if (!isTauriRuntime()) return Promise.resolve(() => undefined);
  return listen("prism:script-registry-changed", callback);
}

export function emitClipboardHistorySettingChanged(enabled: boolean): Promise<void> {
  if (!isTauriRuntime()) return Promise.resolve();
  return emit("prism:clipboard-history-setting-changed", { enabled });
}

export function onClipboardHistorySettingChanged(
  callback: (enabled: boolean) => void,
): Promise<() => void> {
  if (!isTauriRuntime()) return Promise.resolve(() => undefined);
  return listen<{ enabled: boolean }>("prism:clipboard-history-setting-changed", (event) => {
    callback(event.payload.enabled);
  });
}

export function getClipboardHistoryEnabled(): Promise<boolean> {
  return invoke<boolean>("get_clipboard_history_enabled");
}

export function setClipboardHistoryEnabled(enabled: boolean): Promise<boolean> {
  return invoke<boolean>("set_clipboard_history_enabled", { enabled });
}

export function searchClipboardHistory(
  query: string,
  limit = 40,
  kind: "all" | "text" | "image" | "files" = "all",
): Promise<ClipboardHistoryEntry[]> {
  return invoke<NativeClipboardHistoryEntry[]>("search_clipboard_history", { query, limit, ...(kind !== "all" ? { kind } : {}) }).then(
    (entries) => entries.map((entry) => ({
      id: entry.id,
      content: entry.content ?? entry.text ?? "",
      capturedAt: entry.capturedAt ?? entry.capturedAtMs ?? 0,
      pinned: entry.pinned ?? false,
      kind: entry.kind ?? "text",
      mimeType: entry.mimeType ?? null,
      byteSize: entry.byteSize ?? 0,
      width: entry.width ?? null,
      height: entry.height ?? null,
      fileCount: entry.fileCount ?? 0,
      available: entry.available ?? (entry.kind === "files" ? null : true),
    })),
  );
}

export function copyClipboardHistoryEntry(id: number): Promise<void> {
  return invoke("copy_clipboard_history_entry", { id });
}

export function clearClipboardHistory(): Promise<number | undefined> {
  return invoke<number | null>("clear_clipboard_history").then((removed) =>
    typeof removed === "number" ? removed : undefined,
  );
}

export function manageNativeWindow(action: WindowManagementAction): Promise<WindowManagementResult> {
  return invoke<WindowManagementResult>("manage_window", { action });
}

export function getAccessibilityPermissionStatus(): Promise<AccessibilityPermissionStatus> {
  return invoke<AccessibilityPermissionStatus>("refresh_accessibility_permission");
}

export function requestAccessibilityPermission(): Promise<AccessibilityPermissionStatus> {
  return invoke<AccessibilityPermissionStatus>("request_accessibility_permission");
}

export function openAccessibilitySettings(): Promise<void> {
  return invoke("open_accessibility_settings");
}

export function getCommandShortcuts(): Promise<CommandShortcut[]> {
  return invoke<NativeCommandShortcut[]>("get_command_shortcuts").then((settings) =>
    settings.map((setting) => ({
      ...setting,
      accelerator: setting.accelerator ?? setting.shortcut ?? "",
    })),
  );
}

export function onCommandShortcutsChanged(callback: (settings: CommandShortcut[]) => void): Promise<() => void> {
  return listen<NativeCommandShortcut[]>("prism:command-shortcuts-changed", event => callback(event.payload.map(setting => ({ ...setting, accelerator: setting.accelerator ?? setting.shortcut ?? "" }))));
}

export function setCommandShortcut(commandId: string, shortcut: string): Promise<CommandShortcut> {
  return invoke<NativeCommandShortcut>("set_command_shortcut", { commandId, shortcut }).then(
    (setting) => ({
      ...setting,
      accelerator: setting.accelerator ?? setting.shortcut ?? shortcut,
    }),
  );
}

export function removeCommandShortcut(commandId: string): Promise<void> {
  return invoke("remove_command_shortcut", { commandId });
}

export function onCommandHotkey(callback: (payload: CommandHotkeyPayload) => void): Promise<() => void> {
  if (!isTauriRuntime()) return Promise.resolve(() => undefined);
  return listen<CommandHotkeyPayload>("prism:command-hotkey", (event) => callback(event.payload));
}

export function emitPreferencesChanged(preferences: unknown): Promise<void> {
  if (!isTauriRuntime()) return Promise.resolve();
  return emit("prism:preferences-changed", preferences);
}

export function onPreferencesChanged(callback: (preferences: unknown) => void): Promise<() => void> {
  if (!isTauriRuntime()) return Promise.resolve(() => undefined);
  return listen<unknown>("prism:preferences-changed", (event) => callback(event.payload));
}

export function clipboardHistoryItems(entries: ClipboardHistoryEntry[]): CommandItem[] {
  return entries.map((entry): CommandItem => ({
    id: `clipboard:entry:${entry.id}`,
    providerId: "native-clipboard-history",
    title: entry.content.replace(/\s+/g, " ").trim() || "Empty clipboard entry",
    subtitle: new Date(entry.capturedAt).toLocaleString(),
    section: t("Clipboard History"),
    kind: "command",
    keywords: ["clipboard", "paste", "copy", "history"],
    icon: entry.kind === "image" ? "file-image" : entry.kind === "files" ? "file" : "clipboard",
    accent: "violet",
    data: { historyId: entry.id, previewText: entry.content, capturedAt: entry.capturedAt, pinned: entry.pinned ?? false, clipboardKind: entry.kind ?? "text", mimeType: entry.mimeType ?? "", available: entry.available ?? (entry.kind === "files" ? null : true), byteSize: entry.byteSize ?? 0, fileCount: entry.fileCount ?? 0, width: entry.width ?? 0, height: entry.height ?? 0 },
    actions: [
      { id: "copy-clipboard-history-entry", title: t("Copy to Clipboard"), shortcut: ["↵"], style: "accent" },
      { id: "paste-clipboard-history-entry", title: t("붙여넣기"), shortcut: ["⌘", "Enter"] },
      { id: "pin-clipboard-history-entry", title: t(entry.pinned ? "Unpin entry" : "Pin entry") },
      ...(!entry.kind || entry.kind === "text" ? [{ id: "save-clipboard-as-snippet", title: t("Save as Snippet") }] : []),
      { id: "delete-clipboard-history-entry", title: t("기록에서 삭제"), style: "danger" },
    ],
  }));
}
