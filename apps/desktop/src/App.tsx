import { watchPermissionChanges } from "./settings/permissionRefresh";
import { DEFAULT_BACKGROUND_BLUR, normalizeBackgroundBlur } from "./settings/appearance";
import { PrismMark } from "./PrismMark";
import { normalizeReflections } from "./settings/reflectionPreferences";
import { useGlassRefraction } from "./interaction/useGlassRefraction";
import { ClipboardSettings } from "./clipboard/ClipboardSettings";
import { RaycastImport } from "./backup/RaycastImport";
import { BackupSettings } from "./backup/BackupSettings";
import { mergeSafePreferences } from "./backup/backup";
import { loadPreferences, persistPreferences, recoverPreferences, restoreReviewedBackupPreferences } from "./backup/preferencesPersistence";
import { PreferencesRecovery } from "./backup/PreferencesRecovery";
import { SnippetExpansionSettings } from "./snippets/SnippetExpansionSettings";
import { ClipboardTypeFilter } from "./clipboard/ClipboardTypeFilter";
import { ClipboardEntryPreview } from "./clipboard/ClipboardEntryPreview";
import { getClipboardHistoryEntryText, setClipboardHistoryEntryPinned } from "./providers/clipboard";
import { ScriptRunPanel } from "./scripts/ScriptRunPanel";
import { startScriptSession } from "./scripts/runStore";
import { LibraryRunDialog, needsLibraryRun, type LibraryRunAction } from "./library/LibraryRunDialog";
import { SettingsView, type SettingsPreferences as Preferences, type ThemePreference } from "./settings/SettingsView";
import { t, useLocale, localizeCommand, bilingual, notifyLanguageChanged, type Language } from "./i18n";
import { LibraryPanel } from "./LibraryPanel";
import { fileIcons } from "./fileIcons";
import { resultSubtitle } from "./resultPresentation";
import { prepareWindowPresentation } from "./windowPresentation";
import { emptyLibrary, loadLibrary, watchLibrary, watchFileIndex, libraryProvider, fileProvider, type LibraryData, type LibraryEntry } from "./providers/library";
import { invoke } from "@tauri-apps/api/core";
import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import {
  AppWindow,
  Sparkles,
  Mic,
  Star,
  ArrowLeft,
  BatteryCharging,
  Bell,
  Bluetooth,
  BoxSelect,
  Calculator,
  Check,
  Clock3,
  CircleDashed,
  Clipboard,
  ClipboardX,
  Command,
  Copy,
  Coins,
  EyeOff,
  ExternalLink,
  FolderOpen,
  Globe2,
  History,
  Keyboard,
  LockKeyhole,
  LogOut,
  MoonStar,
  Maximize2,
  Monitor,
  MousePointer2,
  Network,
  Paintbrush,
  PanelLeft,
  PanelRight,
  PanelsTopLeft,
  Plus,
  Power,
  RefreshCw,
  Scan,
  Pin,
  Settings,
  Settings2,
  ShieldCheck,
  Smile,
  Sun,
  SunMoon,
  Terminal,
  Trash2,
  TriangleAlert,
  Volume2,
  type LucideIcon,
} from "lucide-react";
import {
  rankCommands,
  searchProviders,
  type CommandAction,
  type CommandDefinition,
  type CommandItem,
  type ProviderFailure,
} from "@prism/command-core";
import {
  isTauriRuntime,
  clearNativeApplicationIconCache,
  clearClipboardHistory,
  clipboardHistoryItems,
  createApplicationAliasProvider,
  copyClipboardHistoryEntry,
  emitClipboardHistorySettingChanged,
  emitScriptRegistryChanged,
  emitPreferencesChanged,
  getClipboardHistoryEnabled,
  getAccessibilityPermissionStatus,
  getNativeApplication,
  getCommandShortcuts,
  onCommandShortcutsChanged,
  getResolvedNativeIcon,
  loadNativeIcon,
  nativeApplicationCommandId,
  nativeApplicationItem,
  nativeApplicationProvider,
  manageNativeWindow,
  onCommandHotkey,
  onClipboardHistorySettingChanged,
  onNativeApplicationIndexUpdated,
  onNativeApplicationIconCacheCleared,
  onPreferencesChanged,
  onScriptRegistryChanged,
  onNativeSettingsNavigation,
  openNativeApplicationSettings,
  openNativeSettingsWindow,
  openNativeSettingsSection,
  openAccessibilitySettings,
  refreshNativeApplicationCatalog,
  removeCommandShortcut,
  requestAccessibilityPermission,
  runNativeAction,
  searchNativeApplications,
  searchClipboardHistory,
  setClipboardHistoryEnabled,
  setCommandShortcut,
  takePendingNativeSettingsNavigation,
  type AccessibilityPermissionStatus,
  type NativeApplication,
  type NativeSettingsNavigationRequest,
  type WindowManagementAction,
} from "./providers/native";
import {
  nativePrismProvider,
  prismActionIds,
  prismCommandIds,
  prismCommandDefinitions,
  prismProvider,
} from "./providers/prism";
import {
  getGlobalShortcut,
  GlobalShortcutCommandError,
  onGlobalShortcutChanged,
  resetGlobalShortcut,
  setGlobalShortcut,
  type GlobalShortcutSetting,
} from "./providers/shortcut";
import { calculatorActionIds, calculatorProvider } from "./providers/calculator";
import { currencyActionIds, currencyProvider } from "./providers/currency";
import { unitActionIds, unitProvider } from "./providers/units";
import { dateTimeActionIds, dateTimeProvider } from "./providers/datetime";
import {
  nativeScriptCommandProvider,
  refreshScriptCommands,
  getScriptCommandForItem,
  type ScriptCommandSummary,
} from "./providers/scripts";
import {
  getSystemPlatform,
  getDesktopCapabilities,
  runSystemCommand,
  systemActionIds,
  systemCommandDefinitions,
  systemProvider,
} from "./providers/system";
import { runWebAction, webActionIds, webProvider } from "./providers/web";

import { initialNavigation, navigate } from "./interaction/navigation";
import { useAiSurface } from "./interaction/useAiSurface";
import { usePaletteKeyboard } from "./interaction/usePaletteKeyboard";
const EmojiPicker = lazy(() => import("./emoji/EmojiPicker").then(module => ({ default: module.EmojiPicker })));
const AiChat = lazy(() => import("./AiChat").then(module => ({ default: module.AiChat })));
import { InstantAnswer } from "./InstantAnswer";

const providers = isTauriRuntime()
  ? [
      nativeApplicationProvider,
      nativePrismProvider,
      systemProvider,
      calculatorProvider,
      currencyProvider,
      unitProvider,
      dateTimeProvider,
      webProvider,
      nativeScriptCommandProvider,
    ]
  : [prismProvider, systemProvider, unitProvider, dateTimeProvider];
const manageableCommands = prismCommandDefinitions.filter(
  (command) => command.management.canDisable,
);
const manageableCommandIds = new Set(manageableCommands.map((command) => command.id));
const configurableCommandIds = new Set(
  prismCommandDefinitions
    .filter((command) => command.management.canConfigure)
    .map((command) => command.id),
);
const isDisableableCommandId = (id: string): boolean =>
  manageableCommandIds.has(id) || id.startsWith("native:") || id.startsWith("system:");
const isAliasCommandId = (id: string): boolean =>
  configurableCommandIds.has(id) || id.startsWith("native:") || id.startsWith("system:");
const hiddenMaintenanceCommandIds = new Set<string>([
  prismCommandIds.refreshApplications,
  prismCommandIds.clearIconCache,
  prismCommandIds.clearClipboardHistory,
]);
const paletteCommandDefinitions = prismCommandDefinitions.filter(
  (command) => !hiddenMaintenanceCommandIds.has(command.id),
);
const iconMap: Record<string, LucideIcon> = {
  smile: Smile,
  ...fileIcons,
  "app-window": AppWindow,
  "battery-charging": BatteryCharging,
  bell: Bell,
  bluetooth: Bluetooth,
  calculator: Calculator,
  currency: Coins,
  "clock-3": Clock3,
  copy: Copy,
  clipboard: Clipboard,
  "clipboard-x": ClipboardX,
  hide: EyeOff,
  globe: Globe2,
  history: History,
  keyboard: Keyboard,
  "lock-keyhole": LockKeyhole,
  "log-out": LogOut,
  moon: MoonStar,
  power: Power,
  monitor: Monitor,
  mouse: MousePointer2,
  network: Network,
  "panels-top-left": PanelsTopLeft,
  refresh: RefreshCw,
  maximize: Maximize2,
  "panel-left": PanelLeft,
  "panel-right": PanelRight,
  scan: Scan,
  settings: Settings2,
  "shield-check": ShieldCheck,
  "sun-moon": SunMoon,
  terminal: Terminal,
  sparkles: Sparkles,
  mic: Mic,
  trash: Trash2,
  "triangle-alert": TriangleAlert,
  "volume-2": Volume2,
};

const defaultPreferences: Preferences = {
  language: "system",
  theme: "system",
  reduceMotion: false,
  backgroundOpacity: 64,
  backgroundBlur: DEFAULT_BACKGROUND_BLUR,
  showApplicationIcons: true,
  disabledCommandIds: [],
  commandAliases: {},
  scriptDirectories: [],
};

function initialPrismCommands(preferences: Preferences): CommandItem[] {
  const browserCommandIds = new Set<string>([
    prismCommandIds.aiChat,
    prismCommandIds.preferences,
    prismCommandIds.clipboardHistory,
    prismCommandIds.library,
    prismCommandIds.links,
    prismCommandIds.snippets,
    prismCommandIds.files,
    prismCommandIds.theme,
  ]);
  const disabled = new Set(preferences.disabledCommandIds);

  return paletteCommandDefinitions
    .filter((definition) => browserCommandIds.has(definition.id))
    .filter((definition) => !disabled.has(definition.id))
    .map((definition): CommandItem => ({
      ...definition,
      providerId: "prism",
      actions: definition.actions.map((action) => ({ ...action })),
      management: { ...definition.management },
    }));
}

function readStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((item): item is string => typeof item === "string"))];
}

function readScriptDirectories(value: unknown): string[] {
  return readStringArray(value)
    .map((directory) => directory.trim())
    .filter((directory) => directory.length > 0 && directory.length <= 4_096)
    .slice(0, 32);
}

function normalizedAliasKey(alias: string): string {
  return alias.trim().normalize("NFKC").toLocaleLowerCase();
}

function readCommandAliases(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object") return {};
  const aliases: Record<string, string> = {};
  const claimedAliases = new Set<string>();
  for (const [id, rawAlias] of Object.entries(value)) {
    if (typeof rawAlias !== "string" || id.length > 512 || !isAliasCommandId(id)) continue;
    const alias = rawAlias.trimStart().slice(0, 80);
    const normalized = normalizedAliasKey(alias);
    if (!normalized || claimedAliases.has(normalized)) continue;
    claimedAliases.add(normalized);
    aliases[id] = alias;
  }
  return aliases;
}

function readRange(value: unknown, min: number, max: number, fallback: number) {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(max, Math.max(min, value))
    : fallback;
}

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message) return error.message;
  if (error && typeof error === "object" && "message" in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string" && message) return message;
  }
  if (typeof error === "string" && error) return error;
  return fallback;
}

function scriptRegistrySummary(
  commandCount: number,
  scannedDirectories: number,
  skippedEntries: number,
): string {
  const skipped = skippedEntries ? t(" · {0} skipped",{0:skippedEntries}) : "";
  return t("{0} commands from {1} folders{2}",{0:commandCount,1:scannedDirectories,2:skipped});
}

function normalizePreferences(value: unknown): Preferences {
  const stored = value && typeof value === "object" ? value as Partial<Preferences> : null;
  const storedOpacity = readRange(stored?.backgroundOpacity, 10, 100, defaultPreferences.backgroundOpacity);
  return {
    language: stored?.language === "en" || stored?.language === "ko" ? stored.language : "system",
    theme: stored?.theme === "dark" || stored?.theme === "light" ? stored.theme : "system",
    reduceMotion: Boolean(stored?.reduceMotion),
    ...normalizeReflections(stored),
    prismHighlights: stored?.prismHighlights === true,
    backgroundOpacity: storedOpacity,
    backgroundBlur: normalizeBackgroundBlur(stored?.backgroundBlur),
    showApplicationIcons: stored?.showApplicationIcons !== false,
    disabledCommandIds: readStringArray(stored?.disabledCommandIds)
      .filter((id) => id.length <= 512 && isDisableableCommandId(id)),
    commandAliases: readCommandAliases(stored?.commandAliases),
    scriptDirectories: readScriptDirectories(stored?.scriptDirectories),
  };
}

function readPreferences() {
  return loadPreferences(localStorage, value => normalizePreferences(value as Partial<Preferences>), defaultPreferences);
}

function Keycap({ children }: { children: string }) {
  useLocale();
  return <kbd>{children}</kbd>;
}

function Shortcut({ keys }: { keys?: string[] }) {
  useLocale();
  if (!keys?.length) return null;
  const commandKey = /Mac|iPhone|iPad/.test(navigator.userAgent);
  const displayKeys = keys.map((key) => key === "⌘" && !commandKey ? "Ctrl" : key);
  return (
    <span className="shortcut" aria-label={displayKeys.join(" plus ")}>
      {displayKeys.map((key, index) => (
        <Keycap key={`${key}-${index}`}>{key}</Keycap>
      ))}
    </span>
  );
}

function CommandGlyph({
  item,
  showApplicationIcons,
  cacheVersion,
}: {
  item: CommandItem;
  showApplicationIcons: boolean;
  cacheVersion: number;
}) {
  useLocale();
  const glyphRef = useRef<HTMLSpanElement>(null);
  const nativeIconEnabled = item.kind !== "application" || showApplicationIcons;
  const cachedIcon = item.iconTarget && nativeIconEnabled
    ? getResolvedNativeIcon(item.iconTarget)
    : undefined;
  const [resolvedIconUrl, setResolvedIconUrl] = useState(item.iconUrl ?? cachedIcon ?? undefined);
  const Icon = iconMap[item.icon ?? ""] ?? (item.kind === "file" ? fileIcons.file : Command);
  const layout = item.icon?.startsWith("window-layout:") ? item.icon.slice("window-layout:".length) : undefined;
  const requiresSystemArtwork = item.iconTarget?.startsWith("system:");

  useEffect(() => {
    let active = true;
    let observer: IntersectionObserver | undefined;
    const iconTarget = item.iconTarget;
    const iconEnabled = item.kind !== "application" || showApplicationIcons;
    const resolved = iconTarget && iconEnabled ? getResolvedNativeIcon(iconTarget) : undefined;
    setResolvedIconUrl(iconEnabled ? item.iconUrl ?? resolved ?? undefined : undefined);

    if (item.iconUrl || resolved !== undefined || !iconEnabled || !iconTarget) return;

    const loadIcon = () => {
      void loadNativeIcon(iconTarget).then((iconUrl) => {
        if (!active) return;
        setResolvedIconUrl(iconUrl);
      });
    };

    if (!glyphRef.current || !("IntersectionObserver" in window)) {
      loadIcon();
    } else {
      observer = new IntersectionObserver(
        ([entry]) => {
          if (!entry.isIntersecting) return;
          observer?.disconnect();
          loadIcon();
        },
        { rootMargin: "140px 0px" },
      );
      observer.observe(glyphRef.current);
    }

    return () => {
      active = false;
      observer?.disconnect();
    };
  }, [cacheVersion, item.iconTarget, item.iconUrl, item.kind, showApplicationIcons]);

  return (
    <span
      ref={glyphRef}
      className={`command-glyph accent-${item.accent ?? "neutral"} ${resolvedIconUrl ? "has-image" : ""}`}
    >
      {layout ? (
        <span className={`window-layout-icon layout-${layout}`} aria-hidden="true"><span /></span>
      ) : item.icon === "prism" ? (
        <PrismMark />
      ) : resolvedIconUrl ? (
        <img src={resolvedIconUrl} alt="" draggable={false} />
      ) : requiresSystemArtwork ? (
        <span className="native-icon-placeholder" aria-hidden="true" />
      ) : (
        <Icon size={16} strokeWidth={1.7} />
      )}
    </span>
  );
}

function EmptyState({
  query,
  hasFailure,
  clipboardView = false,
  clipboardEnabled = true,
}: {
  query: string;
  hasFailure: boolean;
  clipboardView?: boolean;
  clipboardEnabled?: boolean;
}) {
  useLocale();
  const title = clipboardView
    ? clipboardEnabled ? t("No clipboard items") : t("Clipboard History is off")
    : hasFailure ? t("This source is taking a break") : t("No results");
  const description = clipboardView
    ? clipboardEnabled
      ? query ? t("No copied text matches “{0}”.", {"0": query}) : t("Copied text will appear here when history is enabled.")
      : t("Enable it in Settings → Clipboard to keep copied text on this device.")
    : hasFailure
      ? t("Clear the query to return to every available command.")
      : t("Nothing matches “{0}”. Try an app, action, or setting.", {"0": query});
  return (
    <div className="empty-state" role="status">
      <CircleDashed size={24} strokeWidth={1.4} />
      <strong>{t(title)}</strong>
      <p>{description}</p>
    </div>
  );
}

function FailureNotice({ failure, onRetry }: { failure: ProviderFailure; onRetry: () => void }) {
  useLocale();
  return (
    <div className="failure-notice" role="status">
      <TriangleAlert size={15} />
      <span>
        <strong>{t(failure.providerLabel)}</strong> · {t(failure.message)}
      </span>
      <button className="clear-search" onClick={onRetry}>{t("Retry")}</button>
    </div>
  );
}

function ActionPanel({
  item,
  actions,
  query,
  onQueryChange,
  activeIndex,
  onActive,
  onSelect,
  onClose,
}: {
  item: CommandItem;
  actions: CommandAction[];
  query: string;
  onQueryChange: (query: string) => void;
  activeIndex: number;
  onActive: (index: number) => void;
  onSelect: (action: CommandAction) => void;
  onClose: () => void;
}) {
  useLocale();
  const panelRef = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    panelRef.current?.querySelector<HTMLInputElement>("input")?.focus();
  }, []);
  useLayoutEffect(() => {
    panelRef.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView?.({ block: "nearest" });
  }, [activeIndex, query]);

  return (
    <div className="panel-backdrop" onMouseDown={onClose}>
      <section
        ref={panelRef}
        className="action-panel"
        role="dialog"
        aria-modal="true"
        aria-label={t("Actions for {0}", {"0": item.title})}
        onMouseDown={(event) => event.stopPropagation()}
        onKeyDown={(event) => {
          if (event.key !== "Tab") return;
          const controls = [...event.currentTarget.querySelectorAll<HTMLElement>('input, button:not([tabindex="-1"])')];
          const current = controls.indexOf(document.activeElement as HTMLElement);
          const next = (current + (event.shiftKey ? -1 : 1) + controls.length) % controls.length;
          event.preventDefault();
          controls[next]?.focus();
        }}
      >
        <header>
          <button className="icon-button" data-close-actions onClick={onClose} aria-label={t("Close actions")}>
            <ArrowLeft size={16} />
          </button>
          <div>
            <strong>{item.title}</strong>
          </div>
        </header>
        <input
          className="action-search"
          aria-label={t("Search actions")}
          role="combobox"
          aria-expanded="true"
          aria-controls="available-actions"
          aria-activedescendant={actions[activeIndex] ? `action-${actions[activeIndex].id}` : undefined}
          placeholder={t("Search actions…")}
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          autoComplete="off"
          spellCheck={false}
        />
        <div id="available-actions" className="action-list" role="listbox" aria-label={t("Available actions")}>
          {actions.map((action, index) => (
            <button
              id={`action-${action.id}`}
              key={action.id}
              tabIndex={-1}
              role="option"
              aria-selected={index === activeIndex}
              className={`action-row ${index === activeIndex ? "active" : ""} ${action.style === "danger" ? "danger" : ""}`}
              onPointerMove={(event) => {
                if (event.movementX !== 0 || event.movementY !== 0) onActive(index);
              }}
              onClick={() => onSelect(action)}
            >
              <span>{t(action.title)}</span>
            </button>
          ))}
          {!actions.length ? <p className="action-empty" role="status">{t("No matching actions")}</p> : null}
        </div>
      </section>
    </div>
  );
}


async function hideWindow() {
  if (!isTauriRuntime()) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().hide();
}

export function App() {
  const locale = useLocale();
  const nativeRuntime = isTauriRuntime();
  const settingsWindow = new URLSearchParams(window.location.search).get("window") === "settings";
  const commandKey = /Mac|iPhone|iPad/.test(navigator.userAgent);
  const defaultAccelerator = commandKey ? "shift+super+Space" : "shift+control+Space";
  const [preferencesLoad, setPreferencesLoad] = useState(readPreferences);
  const [preferences, setPreferences] = useState<Preferences>(preferencesLoad.preferences);
  const [navigation, navigatePalette] = useReducer(navigate, undefined, () =>
    initialNavigation(settingsWindow ? [] : initialPrismCommands(preferences)),
  );
  const { query, view: paletteView, items, selectedIndex, generation: searchGeneration } = navigation;
  const searchAliases = useMemo(() => Object.fromEntries(
    Object.entries(preferences.commandAliases).map(([id, alias]) => [id, [alias]]),
  ), [preferences.commandAliases]);
  const setQuery = useCallback((value: string) => navigatePalette({ type: "query", query: value, aliases: searchAliases }), [searchAliases]);
  const setSelectedIndex = useCallback((index: number | ((current: number) => number)) =>
    navigatePalette({ type: "select", index }), []);
  const [failures, setFailures] = useState<ProviderFailure[]>([]);
  const [searchLoading, setLoading] = useState(false);
  const loading = (navigation.pending || searchLoading) && items.length === 0;
  const [showLoadingIndicator, setShowLoadingIndicator] = useState(false);
  useEffect(() => {
    if (!loading) { setShowLoadingIndicator(false); return; }
    const timer = window.setTimeout(() => setShowLoadingIndicator(true), 150);
    return () => window.clearTimeout(timer);
  }, [loading]);
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [emojiOpen, setEmojiOpen] = useState(false);
  const [scriptView, setScriptView] = useState<ScriptCommandSummary>();
  const [libraryRun, setLibraryRun] = useState<{ entry: LibraryEntry; action: LibraryRunAction }>();
  const [libraryTab, setLibraryTab] = useState<"links"|"snippets"|"files"|"favorites">("links");
  const [fileEntryQuery, setFileEntryQuery] = useState("");
  const [fileEntrySystem, setFileEntrySystem] = useState(false);
  const [libraryEntry, setLibraryEntry] = useState<LibraryEntry>();
  const [libraryData, setLibraryData] = useState<LibraryData>(emptyLibrary);
  const reloadLibrary = useCallback(() => { if(nativeRuntime) void loadLibrary().then(value => { if(value && Array.isArray(value.entries) && Array.isArray(value.favorites)) setLibraryData(value); }).catch(() => {}); }, [nativeRuntime]);
  useEffect(() => { reloadLibrary(); let disposed=false; let stop:(()=>void)|undefined; void watchLibrary(reloadLibrary).then(value=>{if(disposed)value();else stop=value;}); window.addEventListener("focus",reloadLibrary); return ()=>{disposed=true;stop?.();window.removeEventListener("focus",reloadLibrary);}; }, [reloadLibrary]);
  const closeLibrary = () => {setLibraryOpen(false);setLibraryEntry(undefined);reloadLibrary();requestAnimationFrame(()=>inputRef.current?.focus());};
  const [actionItem, setActionItem] = useState<CommandItem>();
  const actionsOpen = Boolean(actionItem);
  const closeActions = useCallback(() => setActionItem(undefined), []);
  const [actionIndex, setActionIndex] = useState(0);
  const [actionQuery, setActionQuery] = useState("");
  const filteredActions = actionItem ? rankCommands(actionItem.actions.map((action): CommandItem => ({
    id: action.id, title: action.title, keywords: bilingual(action.title), section: "", kind: "command", providerId: "actions", actions: [action],
  })), actionQuery).map((item) => item.actions[0]) : [];
  const { open: aiOpen, phase: aiPhase, reducedMotion: aiReducedMotion, change: setAiOpen } = useAiSurface(preferences.reduceMotion);
  const glassRef = useGlassRefraction(aiReducedMotion, !settingsWindow && preferences.openingLightAnimation !== false);
  const [aiVisited, setAiVisited] = useState(false);
  useEffect(() => { if (aiOpen) setAiVisited(true); }, [aiOpen]);
  const [aiEntry, setAiEntry] = useState({ id: 0, text: "" });
  useEffect(() => {
    if (!nativeRuntime || settingsWindow) return;
    void invoke("set_ai_workspace", { expanded: aiOpen || libraryOpen || emojiOpen || Boolean(libraryRun), reduceMotion: aiReducedMotion })
      .catch((error) => { setToast(errorMessage(error, t("채팅 창 크기를 변경하지 못했습니다."))); });
  }, [aiOpen, libraryOpen, emojiOpen, scriptView, libraryRun, aiReducedMotion, nativeRuntime, settingsWindow]);
  const [preferencesOpen, setPreferencesOpen] = useState(settingsWindow);
  const [shortcut, setShortcut] = useState<GlobalShortcutSetting>({
    accelerator: defaultAccelerator,
    defaultAccelerator,
    isDefault: true,
    registered: false,
    issue: null,
  });
  const [shortcutDraft, setShortcutDraft] = useState(defaultAccelerator);
  const [shortcutError, setShortcutError] = useState("");
  const [shortcutBusy, setShortcutBusy] = useState(false);
  const [shortcutRecording, setShortcutRecording] = useState(false);
  const [clipboardEnabled, setClipboardEnabledState] = useState(false);
  const [clipboardType, setClipboardType] = useState<"all" | "text" | "image" | "files">("all");
  const [clipboardBusy, setClipboardBusy] = useState(false);
  const [clipboardError, setClipboardError] = useState("");
  const [commandShortcuts, setCommandShortcutsState] = useState<Record<string, string>>({});
  const [commandHotkeyRecording, setCommandHotkeyRecording] = useState<string>();
  const [commandHotkeyBusy, setCommandHotkeyBusy] = useState<string>();
  const [commandHotkeyError, setCommandHotkeyError] = useState("");
  const [commandHotkeyRuntimeError, setCommandHotkeyRuntimeError] = useState("");
  const [systemCommands, setSystemCommands] = useState<readonly CommandDefinition[]>([]);
  const [settingsNavigation, setSettingsNavigation] = useState<NativeSettingsNavigationRequest | undefined>(
    () => settingsWindow ? (takePendingNativeSettingsNavigation() ?? (new URLSearchParams(window.location.search).get("section") === "ai" ? { section: "ai" } : undefined)) : undefined,
  );
  const [scriptRegistryBusy, setScriptRegistryBusy] = useState(false);
  const [scriptRegistryStatus, setScriptRegistryStatus] = useState(
    nativeRuntime ? t("Waiting for the startup refresh.") : t("Script commands require the desktop app."),
  );
  const [scriptRegistryError, setScriptRegistryError] = useState("");
  const [accessibilityPermission, setAccessibilityPermission] = useState<AccessibilityPermissionStatus>({
    supported: false,
    granted: false,
    canRequest: false,
    message: t("Accessibility permission is available in Prism for macOS."),
  });
  const [permissionPromptPending, setPermissionPromptPending] = useState(false);
  const [accessibilityPermissionBusy, setAccessibilityPermissionBusy] = useState(false);
  const [accessibilityPermissionError, setAccessibilityPermissionError] = useState("");
  const [catalogRevision, setCatalogRevision] = useState(0);
  useEffect(() => {
    if (!nativeRuntime || settingsWindow) return;
    let disposed = false;
    let stop: (() => void) | undefined;
    void watchFileIndex(() => setCatalogRevision(value => value + 1))
      .then(unlisten => { if (disposed) unlisten(); else stop = unlisten; })
      .catch(error => console.error("Prism could not observe file index updates", error));
    return () => { disposed = true; stop?.(); };
  }, [nativeRuntime, settingsWindow]);
  const [iconCacheRevision, setIconCacheRevision] = useState(0);
  const [maintenanceTask, setMaintenanceTask] = useState<"refresh" | "clear">();
  const [toast, setToast] = useState("");
  const [pointerActive, setPointerActive] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const resultsScrollRef = useRef<HTMLDivElement>(null);
  const resultRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const keyboardNavigation = useRef(false);
  const nativeActionInFlight = useRef(false);
  const preferencesRef = useRef(preferences);
  const executeCommandRef = useRef<(commandId: string, background?: boolean) => void>(() => undefined);

  const selectedItem = items[selectedIndex];
  const answerOverview = items.filter((item) => item.answer?.kind === "currency").length > 1;
  const hasAnswers = items.some((item) => item.answer);

  const updatePreferences = useCallback((next: Preferences) => {
    const normalized = normalizePreferences(next);
    try {
      const { snapshotSaved } = persistPreferences(localStorage, normalized);
      if (!snapshotSaved) setToast(t("설정은 저장했지만 복구용 사본을 저장하지 못했습니다."));
    } catch (error) {
      setPreferencesLoad(readPreferences());
      setToast(errorMessage(error, t("설정을 저장하지 못했습니다.")));
      return false;
    }
    preferencesRef.current = normalized;
    setPreferences(normalized);
    setPreferencesLoad(readPreferences());
    notifyLanguageChanged();
    void emitPreferencesChanged(normalized).catch((error) => {
      console.error("Prism could not broadcast preferences", error);
    });
    return true;
  }, []);

  useEffect(() => {
    if (accessibilityPermission.granted) { setPermissionPromptPending(false); return; }
    if (!permissionPromptPending) return;
    const timer = window.setTimeout(() => setPermissionPromptPending(false), 60000);
    return () => window.clearTimeout(timer);
  }, [accessibilityPermission.granted, permissionPromptPending]);

  const permissionRevision = useRef(0);
  const refreshAccessibilityPermission = useCallback(async (quiet = false) => {
    if (!nativeRuntime) return;
    const revision = ++permissionRevision.current;
    if (!quiet) setAccessibilityPermissionBusy(true);
    setAccessibilityPermissionError("");
    try {
      const status = await getAccessibilityPermissionStatus();
      if (revision === permissionRevision.current) setAccessibilityPermission(status);
    } catch (error) {
      if (revision === permissionRevision.current) setAccessibilityPermissionError(errorMessage(error, t("Prism could not check Accessibility permission.")));
    } finally {
      if (revision === permissionRevision.current) setAccessibilityPermissionBusy(false);
    }
  }, [nativeRuntime]);

  useEffect(() => {
    let active = true;
    let stopListening: (() => void) | undefined;
    const applyExternalPreferences = () => {
      if (!active) return;
      // Both notifications are invalidations of shared localStorage. Replaying
      // their payloads can restore an older slider value, and writing it here
      // starts a storage-event ping-pong between WebViews.
      const loaded = readPreferences();
      setPreferencesLoad(loaded);
      if (loaded.status !== "ok") return;
      const next = loaded.preferences;
      if (JSON.stringify(next) === JSON.stringify(preferencesRef.current)) return;
      preferencesRef.current = next;
      setPreferences(next);
      notifyLanguageChanged();
      setCatalogRevision((revision) => revision + 1);
    };
    const onStorage = (event: StorageEvent) => {
      if (event.storageArea && event.storageArea !== localStorage) return;
      if (event.key === "prism:preferences") applyExternalPreferences();
    };
    window.addEventListener("storage", onStorage);
    void onPreferencesChanged(applyExternalPreferences).then((unlisten) => {
      if (active) stopListening = unlisten;
      else unlisten();
    });
    return () => {
      active = false;
      window.removeEventListener("storage", onStorage);
      stopListening?.();
    };
  }, []);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    let stopListening: (() => void) | undefined;
    void onClipboardHistorySettingChanged((enabled) => {
      if (!active) return;
      setClipboardEnabledState(enabled);
      setCatalogRevision((revision) => revision + 1);
    }).then((unlisten) => {
      if (active) stopListening = unlisten;
      else unlisten();
    }).catch((error) => {
      console.error("Prism could not listen for clipboard setting changes", error);
    });
    return () => {
      active = false;
      stopListening?.();
    };
  }, [nativeRuntime]);

  useEffect(() => {
    let active = true;
    void Promise.all([getSystemPlatform(), getDesktopCapabilities()])
      .then(([platform, capabilities]) => {
        if (active) setSystemCommands(systemCommandDefinitions(platform, capabilities));
      })
      .catch((error) => {
        console.error("Prism could not load system command definitions", error);
      });
    return () => {
      active = false;
    };
  }, [nativeRuntime]);

  useEffect(() => {
    if (!nativeRuntime || !settingsWindow) return;
    let active = true;
    let stopListening: (() => void) | undefined;
    void onNativeSettingsNavigation((request) => {
      if (active) setSettingsNavigation({ ...request });
    }).then((unlisten) => {
      if (active) stopListening = unlisten;
      else unlisten();
    }).catch((error) => {
      console.error("Prism could not listen for Settings navigation", error);
    });
    return () => {
      active = false;
      stopListening?.();
    };
  }, [nativeRuntime, settingsWindow]);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    let stopListening: (() => void) | undefined;
    void onScriptRegistryChanged(() => {
      if (active) setCatalogRevision((revision) => revision + 1);
    }).then((unlisten) => {
      if (active) stopListening = unlisten;
      else unlisten();
    }).catch((error) => {
      console.error("Prism could not listen for script registry changes", error);
    });
    return () => {
      active = false;
      stopListening?.();
    };
  }, [nativeRuntime]);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    setScriptRegistryBusy(true);
    setScriptRegistryError("");
    const directories = readPreferences().preferences.scriptDirectories;
    void refreshScriptCommands({ directories })
      .then((result) => {
        if (!active) return;
        setScriptRegistryStatus(
          t("Startup refresh · {0}", {"0": scriptRegistrySummary(result.commands.length, result.scannedDirectories, result.skippedEntries)}),
        );
        setCatalogRevision((revision) => revision + 1);
        void emitScriptRegistryChanged().catch((error) => {
          console.error("Prism could not broadcast the startup script registry refresh", error);
        });
      })
      .catch((error) => {
        if (!active) return;
        const message = errorMessage(error, t("The startup script registry refresh failed."));
        setScriptRegistryStatus(t("Startup refresh failed."));
        setScriptRegistryError(message);
      })
      .finally(() => {
        if (active) setScriptRegistryBusy(false);
      });
    return () => {
      active = false;
    };
  }, [nativeRuntime]);

  useLayoutEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const applyTheme = () => {
      const resolved = preferences.theme === "system" ? (media.matches ? "dark" : "light") : preferences.theme;
      document.documentElement.dataset.theme = resolved;
      document.documentElement.dataset.reduceMotion = String(preferences.reduceMotion);
      const reflections = normalizeReflections(preferences);
      document.documentElement.style.setProperty("--reflection-intensity", String(reflections.reflectionIntensity / 100));
      document.documentElement.style.setProperty("--reflection-edge", String(reflections.reflectionEdge / 100));
      document.documentElement.style.setProperty("--reflection-highlight", String(reflections.reflectionHighlight / 100));
      document.documentElement.style.setProperty("--reflection-period", `${reflections.reflectionSpeed}s`);
      document.documentElement.style.setProperty("--background-opacity", String(preferences.backgroundOpacity / 100));
      document.documentElement.style.setProperty("--background-blur", `${preferences.backgroundBlur}px`);
    };
    applyTheme();
    media.addEventListener("change", applyTheme);
    return () => media.removeEventListener("change", applyTheme);
  }, [preferences]);

  useEffect(() => {
    if (!nativeRuntime) return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    let cancelPresentation: (() => void) | undefined;
    const applyAppearance = () => {
      cancelPresentation?.();
      const dark = preferences.theme === "system" ? media.matches : preferences.theme === "dark";
      cancelPresentation = prepareWindowPresentation(dark, preferences.backgroundBlur);
    };
    applyAppearance();
    media.addEventListener("change", applyAppearance);
    return () => {
      cancelPresentation?.();
      media.removeEventListener("change", applyAppearance);
    };
  }, [preferences.theme, preferences.backgroundBlur, nativeRuntime]);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    void getGlobalShortcut()
      .then((setting) => {
        if (!active) return;
        setShortcut(setting);
        setShortcutDraft(setting.accelerator);
        setShortcutError(setting.issue?.message ?? "");
      })
      .catch((error) => {
        if (!active) return;
        if (error instanceof GlobalShortcutCommandError) {
          setShortcut(error.active);
          setShortcutDraft(error.active.accelerator);
        }
        setShortcutError(error instanceof Error ? error.message : t("Prism could not read the global shortcut."));
      });
    return () => {
      active = false;
    };
  }, [nativeRuntime]);

  useEffect(() => {
    if (!nativeRuntime) return;
    void refreshAccessibilityPermission();
    const stop = watchPermissionChanges(() => void refreshAccessibilityPermission(true));
    const timer = (preferencesOpen || settingsWindow) ? window.setInterval(() => void refreshAccessibilityPermission(true), 2000) : undefined;
    return () => { permissionRevision.current++; stop(); window.clearInterval(timer); };
  }, [nativeRuntime, refreshAccessibilityPermission, preferencesOpen, settingsWindow]);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    let unlisten: (() => void) | undefined;
    void onGlobalShortcutChanged((setting) => {
      if (!active) return;
      setShortcut(setting);
      setShortcutDraft(setting.accelerator);
      setShortcutError(setting.issue?.message ?? "");
    }).then((stopListening) => {
      if (active) unlisten = stopListening;
      else stopListening();
    }).catch((error) => {
      console.error("Prism could not listen for global shortcut changes", error);
    });
    return () => {
      active = false;
      unlisten?.();
    };
  }, [nativeRuntime, settingsWindow]);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true; let unlisten: (() => void) | undefined;
    void onCommandShortcutsChanged(settings => {
      if (!active) return;
      setCommandShortcutsState(Object.fromEntries(settings.map(({ commandId, accelerator }) => [commandId, accelerator])));
      // Permission polling describes registered shortcuts, not a failed save.
      // Keep the user's last registration error until they explicitly retry.
      setCommandHotkeyRuntimeError(settings.find(setting => setting.issue)?.issue?.message ?? "");
    }).then(stop => { if (active) unlisten = stop; else stop(); }).catch(() => {});
    return () => { active = false; unlisten?.(); };
  }, [nativeRuntime]);

  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    void Promise.all([getClipboardHistoryEnabled(), getCommandShortcuts()])
      .then(async ([enabled, shortcuts]) => {
        if (!active) return;
        let activeShortcuts = shortcuts;
        let failedShortcutIds = new Set<string>();
        if (!settingsWindow) {
          const disabled = new Set(readPreferences().preferences.disabledCommandIds);
          const staleShortcuts = shortcuts.filter(({ commandId }) => disabled.has(commandId));
          const removals = await Promise.allSettled(
            staleShortcuts.map(({ commandId }) => removeCommandShortcut(commandId)),
          );
          if (!active) return;
          failedShortcutIds = new Set(
            staleShortcuts
              .filter((_, index) => removals[index]?.status === "rejected")
              .map(({ commandId }) => commandId),
          );
          activeShortcuts = shortcuts.filter(
            ({ commandId }) => !disabled.has(commandId) || failedShortcutIds.has(commandId),
          );
          if (failedShortcutIds.size) {
            setCommandHotkeyError(t("Some disabled command shortcuts could not be released."));
          }
        }
        setClipboardEnabledState(enabled);
        setCommandShortcutsState(Object.fromEntries(activeShortcuts.map(({ commandId, accelerator }) => [commandId, accelerator])));
        const shortcutIssue = activeShortcuts.find((setting) => setting.issue)?.issue;
        setCommandHotkeyRuntimeError(shortcutIssue?.message ?? "");
      })
      .catch((error) => {
        if (!active) return;
        setClipboardError(errorMessage(error, t("Native preferences could not be loaded.")));
      });
    return () => {
      active = false;
    };
  }, [nativeRuntime, settingsWindow]);

  useEffect(() => {
    if (!isTauriRuntime() || settingsWindow) return;
    let active = true;
    let unlisten: (() => void) | undefined;
    void onNativeApplicationIndexUpdated(() => {
      if (active) setCatalogRevision((revision) => revision + 1);
    }).then((stopListening) => {
      if (active) unlisten = stopListening;
      else stopListening();
    }).catch((error) => {
      console.error("Prism could not listen for application index updates", error);
    });
    return () => {
      active = false;
      unlisten?.();
    };
  }, [settingsWindow]);

  useEffect(() => {
    if (!isTauriRuntime() || settingsWindow) return;
    let active = true;
    let unlisten: (() => void) | undefined;
    void onNativeApplicationIconCacheCleared(() => {
      if (active) setIconCacheRevision((revision) => revision + 1);
    }).then((stopListening) => {
      if (active) unlisten = stopListening;
      else stopListening();
    }).catch((error) => {
      console.error("Prism could not listen for icon cache changes", error);
    });
    return () => {
      active = false;
      unlisten?.();
    };
  }, [settingsWindow]);

  useEffect(() => {
    const receiveResults = (next: CommandItem[]) =>
      navigatePalette({ type: "results", generation: searchGeneration, items: next });
    if (settingsWindow) {
      setLoading(false);
      receiveResults([]);
      setFailures([]);
      return;
    }
    const controller = new AbortController();
    if (paletteView === "clipboard") {
      setFailures([]);
      if (!nativeRuntime || !clipboardEnabled) {
        receiveResults([]);
        setLoading(false);
        return () => controller.abort();
      }
      setLoading(true);
      void searchClipboardHistory(query, query.trim() ? 40 : 24, clipboardType)
        .then((entries) => {
          if (controller.signal.aborted) return;
          receiveResults(clipboardHistoryItems(entries).map(localizeCommand));
          setLoading(false);
        })
        .catch((error) => {
          if (controller.signal.aborted) return;
          receiveResults([]);
          setFailures([{ providerId: "native-clipboard-history", providerLabel: t("Clipboard History"), message: errorMessage(error, t("Clipboard history is unavailable.")) }]);
          setLoading(false);
        });
      return () => controller.abort();
    }
    const aliases = searchAliases;
    const sources = nativeRuntime ? [...providers, libraryProvider(libraryData, paletteCommandDefinitions.map(item=>({...item,providerId:"prism"}))), fileProvider] : providers;
    const activeProviders = nativeRuntime && query.trim()
      ? [...sources, createApplicationAliasProvider(aliases)] : sources;
    void searchProviders(activeProviders, query, controller.signal, aliases, {
      onUpdate: (response, pending, pendingProviderIds) => {
        if (controller.signal.aborted) return;
        const disabled = new Set(preferences.disabledCommandIds);
        const itemById = new Map(response.items.map(localizeCommand).map((item) => [item.id, item]));
        const nextItems = [...itemById.values()].filter((item) => !disabled.has(item.id)).map(item => {
          const order=libraryData.favorites.findIndex(f=>f.id===item.id); return {...item,favoriteOrder:order>=0?order:undefined};
        });
        navigatePalette({ type: "results", generation: searchGeneration, items: nextItems, pendingProviderIds, aliases });
        setFailures(response.failures);
        setLoading(pending > 0 && nextItems.length === 0);
      },
    }).catch((error) => {
      if (controller.signal.aborted) return;
      receiveResults([]);
      setLoading(false);
      setFailures([{ providerId: "search", providerLabel: t("Search"), message: errorMessage(error, t("Search could not be completed.")) }]);
    });
    return () => {
      controller.abort();
    };
  }, [locale, libraryData, catalogRevision, clipboardEnabled, clipboardType, nativeRuntime, paletteView, searchAliases, preferences.disabledCommandIds, query, searchGeneration, settingsWindow]);

  useEffect(() => {
    if (!keyboardNavigation.current) return;
    keyboardNavigation.current = false;

    const container = resultsScrollRef.current;
    const row = resultRefs.current[selectedIndex];
    if (!container || !row) return;

    const containerBounds = container.getBoundingClientRect();
    const rowBounds = row.getBoundingClientRect();
    if (rowBounds.top < containerBounds.top) {
      container.scrollTop -= containerBounds.top - rowBounds.top;
    } else if (rowBounds.bottom > containerBounds.bottom) {
      container.scrollTop += rowBounds.bottom - containerBounds.bottom;
    }
  }, [selectedIndex]);

  useLayoutEffect(() => {
    resultsScrollRef.current?.scrollTo({ top: navigation.scrollTop });
  }, [navigation.scrollRevision]);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(""), 2600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const resetPaletteState = useCallback(() => {
    navigatePalette({ type: "reset" });
    closeActions();
    setActionIndex(0);
    setPreferencesOpen(settingsWindow);
    setShortcutRecording(false);
    setCommandHotkeyRecording(undefined);
    setShortcutError("");
    setToast("");
    keyboardNavigation.current = false;
    resultsScrollRef.current?.scrollTo({ top: 0 });
  }, [closeActions, settingsWindow]);

  const dismissPalette = useCallback(async () => {
    if (!nativeRuntime) {
      setToast(t("Hide Prism is available in the desktop app"));
      return;
    }
    try {
      await hideWindow();
      setPointerActive(false);
      resetPaletteState();
    } catch (error) {
      setToast(errorMessage(error, t("Prism could not hide its window.")));
    }
  }, [nativeRuntime, resetPaletteState]);

  useEffect(() => {
    if (settingsWindow) {
      const pointerReset = () => setPointerActive(false);
      window.addEventListener("blur", pointerReset);
      return () => window.removeEventListener("blur", pointerReset);
    }
    const focusSearch = () => {
      setPointerActive(false);
      if (!actionsOpen && !preferencesOpen && !aiOpen && !libraryOpen && !emojiOpen && !scriptView && !libraryRun) inputRef.current?.focus();
    };
    const resetAfterFocusLoss = () => {
      setPointerActive(false);
      if (nativeRuntime && shortcut.registered && !aiOpen && !libraryOpen && !emojiOpen && !scriptView && !libraryRun) {
        resetPaletteState();
      }
    };

    window.addEventListener("focus", focusSearch);
    window.addEventListener("blur", resetAfterFocusLoss);
    return () => {
      window.removeEventListener("focus", focusSearch);
      window.removeEventListener("blur", resetAfterFocusLoss);
    };
  }, [actionsOpen, aiOpen, libraryOpen, emojiOpen, scriptView, libraryRun, nativeRuntime, preferencesOpen, resetPaletteState, settingsWindow, shortcut.registered]);

  useEffect(() => {
    if (settingsWindow || actionsOpen || preferencesOpen || aiOpen || libraryOpen || emojiOpen || Boolean(scriptView) || Boolean(libraryRun)) return;
    const frame = requestAnimationFrame(() => inputRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [actionsOpen, aiOpen, libraryOpen, emojiOpen, scriptView, libraryRun, preferencesOpen, settingsWindow, paletteView]);

  const clearQuery = () => {
    setQuery("");
    inputRef.current?.focus();
  };

  const goBack = () => {
    closeActions();
    navigatePalette({ type: "back" });
    setFailures([]);
    setLoading(false);
    inputRef.current?.focus();
  };

  const openActions = () => {
    if (!selectedItem || loading) return;
    setSelectedIndex(selectedIndex);
    setActionQuery("");
    setActionIndex(0);
    const canFavorite=nativeRuntime && !selectedItem.answer && !selectedItem.matchedQuery && ["prism","native-applications","library"].includes(selectedItem.providerId);
    setActionItem(canFavorite ? {...selectedItem,actions:[...selectedItem.actions,{id:"toggle-favorite",title:libraryData.favorites.some(f=>f.id===selectedItem.id)?t("즐겨찾기 해제"):t("즐겨찾기 추가")}]} : selectedItem);
  };

  const cycleTheme = () => {
    const order: ThemePreference[] = ["system", "dark", "light"];
    const theme = order[(order.indexOf(preferences.theme) + 1) % order.length];
    updatePreferences({ ...preferences, theme });
    setToast(t("Appearance set to {0}", {"0": theme}));
  };

  const openPreferences = async () => {
    setShortcutDraft(shortcut.accelerator);
    setShortcutError(shortcut.issue?.message ?? "");
    setShortcutRecording(false);
    if (nativeRuntime) {
      await openNativeSettingsWindow();
      if (!settingsWindow) await dismissPalette();
    } else {
      setPreferencesOpen(true);
    }
  };

  const openAiSettings = async () => {
    try {
      if (nativeRuntime) {
        await openNativeSettingsSection({ section: "ai" });
        if (!settingsWindow) await dismissPalette();
      } else {
        const url = new URL(window.location.href);
        url.search = "?window=settings&section=ai";
        const settingsTab = window.open(url.toString(), "prism-ai-settings");
        if (!settingsTab) setToast(t("설정창 팝업을 허용한 뒤 다시 시도하세요."));
      }
    } catch (error) { setToast(errorMessage(error, t("AI 설정창을 열지 못했습니다."))); }
  };

  const closePreferences = async () => {
    setShortcutRecording(false);
    setCommandHotkeyRecording(undefined);
    setShortcutError("");
    if (nativeRuntime && settingsWindow) {
      const { getCurrentWindow } = await import("@tauri-apps/api/window");
      await getCurrentWindow().close();
      return;
    }
    setPreferencesOpen(false);
    requestAnimationFrame(() => inputRef.current?.focus());
  };

  const recordShortcut = (accelerator: string) => {
    if (!accelerator) {
      setShortcutError(t("Include at least one modifier key in the global shortcut."));
      return;
    }
    setShortcutDraft(accelerator);
    setShortcutError("");
    setShortcutRecording(false);
    void saveShortcut(accelerator);
  };

  const saveShortcut = async (accelerator: string) => {
    if (!nativeRuntime || shortcutBusy) return;
    setShortcutBusy(true);
    setShortcutError("");
    try {
      const setting = await setGlobalShortcut(accelerator);
      setShortcut(setting);
      setShortcutDraft(setting.accelerator);
      setToast(t("Global shortcut updated"));
    } catch (error) {
      if (error instanceof GlobalShortcutCommandError) {
        setShortcut(error.active);
        setShortcutDraft(error.active.accelerator);
      }
      setShortcutError(error instanceof Error ? error.message : t("The global shortcut could not be saved."));
    } finally {
      setShortcutBusy(false);
      setShortcutRecording(false);
    }
  };

  const resetShortcut = async () => {
    if (!nativeRuntime || shortcutBusy) return;
    setShortcutBusy(true);
    setShortcutError("");
    try {
      const setting = await resetGlobalShortcut();
      setShortcut(setting);
      setShortcutDraft(setting.accelerator);
      setToast(t("Global shortcut reset"));
    } catch (error) {
      if (error instanceof GlobalShortcutCommandError) {
        setShortcut(error.active);
        setShortcutDraft(error.active.accelerator);
      }
      setShortcutError(error instanceof Error ? error.message : t("The global shortcut could not be reset."));
    } finally {
      setShortcutBusy(false);
      setShortcutRecording(false);
    }
  };

  const requestAccessibilityAccess = async () => {
    if (!nativeRuntime || accessibilityPermissionBusy) return;
    setPermissionPromptPending(true);
    const revision = ++permissionRevision.current;
    setAccessibilityPermissionBusy(true);
    setAccessibilityPermissionError("");
    try {
      const status = await requestAccessibilityPermission();
      if (revision === permissionRevision.current) setAccessibilityPermission(status);
      setToast(status.granted ? t("Accessibility access is enabled") : t("Complete access in System Settings"));
    } catch (error) {
      setPermissionPromptPending(false);
      setAccessibilityPermissionError(errorMessage(error, t("Prism could not request Accessibility access.")));
    } finally {
      if (revision === permissionRevision.current) setAccessibilityPermissionBusy(false);
    }
  };

  const openAccessibilityPreferences = async () => {
    if (!nativeRuntime || accessibilityPermissionBusy) return;
    setAccessibilityPermissionError("");
    try {
      await openAccessibilitySettings();
    } catch (error) {
      setAccessibilityPermissionError(errorMessage(error, t("Prism could not open Accessibility settings.")));
    }
  };

  const toggleClipboardHistory = async () => {
    if (!nativeRuntime || clipboardBusy) return;
    setClipboardBusy(true);
    setClipboardError("");
    try {
      const enabled = await setClipboardHistoryEnabled(!clipboardEnabled);
      setClipboardEnabledState(enabled);
      setCatalogRevision((revision) => revision + 1);
      await emitClipboardHistorySettingChanged(enabled);
      setToast(enabled ? t("Clipboard history enabled") : t("Clipboard history disabled"));
    } catch (error) {
      setClipboardError(errorMessage(error, t("Clipboard history could not be updated.")));
    } finally {
      setClipboardBusy(false);
    }
  };

  const clearClipboard = async () => {
    if (!nativeRuntime || clipboardBusy) return;
    setClipboardBusy(true);
    setClipboardError("");
    try {
      const removed = await clearClipboardHistory();
      setCatalogRevision((revision) => revision + 1);
      setToast(
        removed === undefined
          ? t("Clipboard history cleared")
          : t("Clipboard history cleared · {0} {1}", {"0": removed,"1": removed === 1 ? "entry" : "entries"}),
      );
    } catch (error) {
      const message = errorMessage(error, t("Clipboard history could not be cleared."));
      setClipboardError(message);
      setToast(message);
    } finally {
      setClipboardBusy(false);
    }
  };

  const saveCommandHotkey = async (commandId: string, accelerator: string) => {
    if (!accelerator) {
      setCommandHotkeyError(t("Include at least one modifier key in a command shortcut."));
      return;
    }
    setCommandHotkeyBusy(commandId);
    setCommandHotkeyError("");
    try {
      const setting = await setCommandShortcut(commandId, accelerator);
      setCommandShortcutsState((current) => ({ ...current, [setting.commandId]: setting.accelerator }));
      setToast(t("Command shortcut updated"));
    } catch (error) {
      setCommandHotkeyError(errorMessage(error, t("The command shortcut could not be saved.")));
    } finally {
      setCommandHotkeyBusy(undefined);
      setCommandHotkeyRecording(undefined);
    }
  };

  const deleteCommandHotkey = async (commandId: string) => {
    setCommandHotkeyBusy(commandId);
    setCommandHotkeyError("");
    try {
      await removeCommandShortcut(commandId);
      setCommandShortcutsState((current) => {
        const next = { ...current };
        delete next[commandId];
        return next;
      });
      setToast(t("Command shortcut removed"));
    } catch (error) {
      setCommandHotkeyError(errorMessage(error, t("The command shortcut could not be removed.")));
    } finally {
      setCommandHotkeyBusy(undefined);
    }
  };

  const changeCommandAlias = (commandId: string, alias: string) => {
    const storedAlias = alias.trimStart().slice(0, 80);
    const normalized = normalizedAliasKey(storedAlias);
    const currentPreferences = preferencesRef.current;
    const duplicate = normalized
      ? Object.entries(currentPreferences.commandAliases).find(
          ([id, existingAlias]) =>
            id !== commandId && normalizedAliasKey(existingAlias) === normalized,
        )
      : undefined;
    if (duplicate) {
      setCommandHotkeyError(t("Alias \"{0}\" is already assigned to another command.", {"0": storedAlias.trim()}));
      return;
    }
    setCommandHotkeyError("");
    const commandAliases = { ...currentPreferences.commandAliases };
    if (normalized) commandAliases[commandId] = storedAlias;
    else delete commandAliases[commandId];
    updatePreferences({
      ...currentPreferences,
      commandAliases,
    });
  };

  const toggleCommand = async (commandId: string) => {
    if (!isDisableableCommandId(commandId)) return;
    const disabling = !preferencesRef.current.disabledCommandIds.includes(commandId);
    if (disabling && nativeRuntime && (commandId === prismCommandIds.dictation || commandId === prismCommandIds.dictationPrompt)) {
      try { await invoke("dictation_action", { action: "cancel" }); }
      catch (error) { setCommandHotkeyError(errorMessage(error, t("받아쓰기를 중단하지 못했습니다."))); return; }
    }
    if (disabling && nativeRuntime && commandShortcuts[commandId]) {
      setCommandHotkeyBusy(commandId);
      setCommandHotkeyError("");
      try {
        await removeCommandShortcut(commandId);
        setCommandShortcutsState((current) => {
          const next = { ...current };
          delete next[commandId];
          return next;
        });
      } catch (error) {
        setCommandHotkeyError(
          errorMessage(error, t("Remove this command's shortcut before disabling it.")),
        );
        return;
      } finally {
        setCommandHotkeyBusy(undefined);
      }
    }
    const currentPreferences = preferencesRef.current;
    const disabledCommandIds = disabling
      ? [...new Set([...currentPreferences.disabledCommandIds, commandId])]
      : currentPreferences.disabledCommandIds.filter((id) => id !== commandId);
    updatePreferences({ ...currentPreferences, disabledCommandIds });
  };

  const refreshApplications = async () => {
    setMaintenanceTask("refresh");
    try {
      const applicationCount = await refreshNativeApplicationCatalog();
      setCatalogRevision((revision) => revision + 1);
      setToast(t("Application index refreshed · {0} apps", {"0": applicationCount}));
    } catch (error) {
      setToast(error instanceof Error ? error.message : t("The application index could not be refreshed."));
    } finally {
      setMaintenanceTask(undefined);
    }
  };

  const refreshScripts = async () => {
    if (!nativeRuntime || scriptRegistryBusy) return;
    setScriptRegistryBusy(true);
    setScriptRegistryError("");
    try {
      const result = await refreshScriptCommands({ directories: preferences.scriptDirectories });
      setScriptRegistryStatus(
        t("Refreshed · {0}", {"0": scriptRegistrySummary(result.commands.length, result.scannedDirectories, result.skippedEntries)}),
      );
      setCatalogRevision((revision) => revision + 1);
      await emitScriptRegistryChanged();
      setToast(t("Script command registry refreshed"));
    } catch (error) {
      const message = errorMessage(error, t("The script command registry could not be refreshed."));
      setScriptRegistryStatus(t("Refresh failed. The previous registry remains active."));
      setScriptRegistryError(message);
      setToast(message);
    } finally {
      setScriptRegistryBusy(false);
    }
  };

  const clearIconCache = async () => {
    setMaintenanceTask("clear");
    try {
      await clearNativeApplicationIconCache();
      setIconCacheRevision((revision) => revision + 1);
      setToast(t("Application icon cache cleared"));
    } catch (error) {
      setToast(error instanceof Error ? error.message : t("The application icon cache could not be cleared."));
    } finally {
      setMaintenanceTask(undefined);
    }
  };

  const reportCommandError = async (message: string, background = false) => {
    setToast(message);
    if (message && background && nativeRuntime) {
      await invoke("reveal_palette").catch(error => console.error("Prism could not show the command error", error));
    }
  };

  const executeAction = async (action: CommandAction, item = selectedItem, background = false) => {
    if (!item) return;
    closeActions();
    if (document.hasFocus()) inputRef.current?.focus();
    try {
      if (action.id === prismActionIds.openEmoji) { setEmojiOpen(true); }
      else if (action.id === "files-search-broader") { setLibraryTab("files"); setFileEntryQuery(String(item.data?.query ?? query)); setFileEntrySystem(true); setLibraryEntry(undefined); setLibraryOpen(true); }
      else if([prismActionIds.openLibrary,prismActionIds.openLinks,prismActionIds.openSnippets,prismActionIds.openFiles].includes(action.id as never)){setLibraryTab(action.id===prismActionIds.openSnippets?"snippets":action.id===prismActionIds.openFiles?"files":"links");setFileEntryQuery("");setFileEntrySystem(false);setLibraryEntry(undefined);setLibraryOpen(true);}
      else if(action.id==="toggle-favorite"){
        await invoke("library_set_favorite",{favorite:{id:item.id,title:item.title},enabled:!libraryData.favorites.some(f=>f.id===item.id)});reloadLibrary();
      }
      else if(action.id.startsWith("library-")){
        if(action.id==="library-edit"){setLibraryEntry(libraryData.entries.find(e=>e.id===item.data?.entryId));setLibraryOpen(true);}
        else {
          const entry = libraryData.entries.find(value => value.id === item.data?.entryId);
          const runAction = action.id.slice(8) as LibraryRunAction;
          if (entry && needsLibraryRun(entry)) setLibraryRun({ entry, action: runAction });
          else { await invoke("library_entry_action", { id: item.data?.entryId, action: runAction }); if (runAction === "copy") setToast(t("복사했습니다.")); else await dismissPalette(); }
        }
      }
      else if(action.id.startsWith("file-")){
        await invoke("library_file_action",{id:item.data?.fileId,action:action.id.slice(5)});if(action.id==="file-open")await dismissPalette();else setToast(action.id==="file-copy"?t("경로를 복사했습니다."):t("Finder에서 열었습니다."));
      }
      else if (action.id === "pin-clipboard-history-entry") {
        await setClipboardHistoryEntryPinned(Number(item.data?.historyId), !item.data?.pinned);
        setCatalogRevision(value => value + 1);
      }
      else if (action.id === "save-clipboard-as-snippet") {
        const value = await getClipboardHistoryEntryText(Number(item.data?.historyId));
        setLibraryEntry({ id: crypto.randomUUID(), kind: "snippet", title: value.replace(/\s+/g, " ").slice(0, 60), value });
        setLibraryTab("snippets"); setLibraryOpen(true);
      }
      else if(action.id==="delete-clipboard-history-entry"){
        await invoke("delete_clipboard_history_entry",{id:Number(item.data?.historyId)});setCatalogRevision(v=>v+1);setToast(t("기록에서 삭제했습니다."));
      }
      else if(action.id==="paste-clipboard-history-entry"){
        await invoke("paste_clipboard_history_entry",{id:Number(item.data?.historyId)});resetPaletteState();
      }
      else if (action.id === prismActionIds.toggleDictation || action.id === prismActionIds.toggleDictationPrompt) {
        if (!nativeRuntime) { setToast(t("받아쓰기는 macOS용 Prism 앱에서 사용할 수 있습니다.")); return; }
        await invoke(action.id === prismActionIds.toggleDictationPrompt ? "dictation_prompt_toggle" : "dictation_toggle"); resetPaletteState();
      }
      else if (action.id === prismActionIds.openAiChat) { closeActions(); setAiOpen(true); }
      else if (action.id === prismActionIds.openPreferences) await openPreferences();
      else if (action.id === prismActionIds.openClipboardHistory) {
        if (!nativeRuntime) {
          setToast(t("Clipboard History is available in the Prism desktop app"));
          return;
        }
        navigatePalette({ type: "clipboard", scrollTop: resultsScrollRef.current?.scrollTop ?? 0 });
        requestAnimationFrame(() => inputRef.current?.focus());
      }
      else if (action.id === prismActionIds.cycleTheme) cycleTheme();
      else if (action.id === prismActionIds.hide) await dismissPalette();
      else if (action.id === prismActionIds.refreshApplications) await refreshApplications();
      else if (action.id === prismActionIds.clearIconCache) await clearIconCache();
      else if (action.id === prismActionIds.clearClipboardHistory) await clearClipboard();
      else if (action.id.startsWith("manage-window-")) {
        if (!nativeRuntime) {
          setToast(t("Window Management is available in the Prism desktop app"));
          return;
        }
        const layout = action.id.slice("manage-window-".length) as WindowManagementAction;
        const result = await manageNativeWindow(layout);
        if (result.applied) await dismissPalette();
        else await reportCommandError(result.message, background);
      }
      else if (action.id === calculatorActionIds.copyResult) {
        await navigator.clipboard.writeText(String(item.data?.result ?? item.title));
        setToast(t("Calculator result copied"));
      }
      else if (action.id === currencyActionIds.copyResult) {
        await navigator.clipboard.writeText(String(item.data?.result ?? ""));
        setToast(t("Converted amount copied"));
      }
      else if (action.id === unitActionIds.copyResult) {
        await navigator.clipboard.writeText(String(item.data?.result ?? ""));
        setToast(t("Conversion result copied"));
      }
      else if (action.id === dateTimeActionIds.copyResult) {
        const text = String(item.data?.result ?? "");
        if (nativeRuntime) await invoke("copy_plain_text", { text }); else await navigator.clipboard.writeText(text);
        setToast(t("복사했습니다."));
      }
      else if (action.id === systemActionIds.openSetting || action.id === systemActionIds.lockScreen || action.id === systemActionIds.power) {
        if (!nativeRuntime) {
          setToast(t("System commands are available in the Prism desktop app"));
          return;
        }
        const result = await runSystemCommand(
          action.id,
          String(item.data?.systemCommandId ?? item.id),
        );
        if (result.applied) await dismissPalette();
        else await reportCommandError(result.message, background);
      }
      else if (action.id === webActionIds.openUrl || action.id === webActionIds.search) {
        await runWebAction(action.id, item.data);
        await dismissPalette();
      }
      else if (item.providerId === nativeScriptCommandProvider.id) {
        const script = await getScriptCommandForItem(item);
        if (!script.arguments?.length && !script.argumentError) void startScriptSession(script.id, []);
        setScriptView(script);
      }
      else if (action.id === "configure-native") {
        await openNativeApplicationSettings({
          applicationId: String(item.data?.applicationId ?? ""),
          applicationName: item.title,
        });
        await dismissPalette();
      }
      else if (action.id === "copy-native-path") {
        await navigator.clipboard.writeText(String(item.data?.target ?? ""));
        setToast(t("Application path copied"));
      } else if (action.id === "copy-clipboard-history-entry") {
        await copyClipboardHistoryEntry(Number(item.data?.historyId));
        setCatalogRevision((revision) => revision + 1);
        setToast(t("Copied to clipboard"));
      } else if (action.id.startsWith("launch-native") || action.id.startsWith("reveal-native")) {
        if (nativeActionInFlight.current) return;
        nativeActionInFlight.current = true;
        try {
          await runNativeAction(
            action.id,
            String(item.data?.applicationId ?? ""),
            String(item.data?.target ?? ""),
          );
          if (action.id === "launch-native") {
            setQuery("");
            setSelectedIndex(0);
            setCatalogRevision((revision) => revision + 1);
            await dismissPalette();
          } else {
            setToast(t("Application revealed"));
          }
        } finally {
          nativeActionInFlight.current = false;
        }
      }
    } catch (error) {
      await reportCommandError(errorMessage(error, t("The action could not be completed.")), background);
    }
  };

  executeCommandRef.current = (commandId: string, background = false) => {
    if (preferences.disabledCommandIds.includes(commandId) || hiddenMaintenanceCommandIds.has(commandId)) return;
    if (commandId.startsWith("native:")) {
      const applicationId = commandId.slice("native:".length);
      void getNativeApplication(applicationId)
        .then((application) => {
          if (!application) {
            return reportCommandError(t("The application is no longer available in the local index"), background);
          }
          return executeAction(nativeApplicationItem(application).actions[0], nativeApplicationItem(application), background);
        })
        .catch((error) => {
          void reportCommandError(errorMessage(error, t("The application shortcut could not be resolved.")), background);
        });
      return;
    }
    const definition = prismCommandDefinitions.find((command) => command.id === commandId)
      ?? systemCommands.find((command) => command.id === commandId);
    if (!definition) {
      void reportCommandError(t("Unknown command shortcut · {0}", {"0": commandId}), background);
      return;
    }
    const providerId = commandId.startsWith("system:") ? systemProvider.id : "prism";
    void executeAction(definition.actions[0], { ...definition, providerId }, background);
  };

  useEffect(() => {
    if (!nativeRuntime || settingsWindow) return;
    let active = true;
    let stopListening: (() => void) | undefined;
    void onCommandHotkey(({ commandId, background }) => {
      if (active) executeCommandRef.current(commandId, background);
    }).then((unlisten) => {
      if (active) stopListening = unlisten;
      else unlisten();
    }).catch((error) => {
      console.error("Prism could not listen for command shortcuts", error);
    });
    return () => {
      active = false;
      stopListening?.();
    };
  }, [nativeRuntime, settingsWindow]);

  usePaletteKeyboard({
    query,
    view: paletteView,
    settings: preferencesOpen || aiOpen || libraryOpen || emojiOpen || Boolean(scriptView) || Boolean(libraryRun),
    recording: shortcutRecording || Boolean(commandHotkeyRecording),
    selectedItem: loading ? undefined : selectedItem,
    actionItem: actionItem ? { ...actionItem, actions: filteredActions } : undefined,
    actionIndex,
    itemCount: items.length,
    input: inputRef,
    cancelRecording: () => {
      setShortcutRecording(false);
      setCommandHotkeyRecording(undefined);
      setShortcutError("");
      setCommandHotkeyError("");
    },
    clearQuery,
    goBack,
    hide: () => { void dismissPalette(); },
    openSettings: () => { void openPreferences(); },
    openAiChat: () => {
      setAiEntry((entry) => ({ id: entry.id + 1, text: /^(ai|chat|대화)$/i.test(query.trim()) ? "" : query }));
      setAiOpen(true);
    },
    openActions,
    closeActions,
    moveSelection: (direction) => {
      keyboardNavigation.current = true;
      setSelectedIndex((current) => current + direction);
    },
    selectAction: setActionIndex,
    execute: (action, item) => { void executeAction(action, item); },
    cycleTheme,
  });

  return (
    <main
      ref={glassRef}
      className={`prism-shell${nativeRuntime ? "" : " browser-preview"}${settingsWindow ? " settings-window" : ""}${(aiOpen || libraryOpen || emojiOpen || libraryRun) && !settingsWindow ? " ai-expanded" : ""} ai-phase-${aiPhase}${pointerActive ? " pointer-active" : ""}`}
      onPointerMove={(event) => {
        if (!pointerActive && (event.movementX !== 0 || event.movementY !== 0)) {
          setPointerActive(true);
        }
      }}
    >
      <div className="drag-handle" data-tauri-drag-region aria-hidden="true" />

      {(aiVisited || aiOpen) && <Suspense fallback={<div className="workspace-loading" role="status">{t("Loading…")}</div>}><AiChat visible={aiOpen && !preferencesOpen && !libraryOpen && !emojiOpen && !scriptView && !libraryRun} closing={aiPhase === "closing"} reduceMotion={aiReducedMotion} entryDraft={aiEntry} nativeRuntime={nativeRuntime} onClose={() => setAiOpen(false)} onOpenSettings={() => void openAiSettings()} /></Suspense>}
      {emojiOpen ? <Suspense fallback={<div className="workspace-loading" role="status">{t("Loading…")}</div>}><EmojiPicker
        onClose={() => { setEmojiOpen(false); requestAnimationFrame(() => inputRef.current?.focus()); }}
        onCopy={async text => { if (nativeRuntime) await invoke("copy_plain_text", { text }); else await navigator.clipboard.writeText(text); }}
        onPaste={nativeRuntime ? async text => { await invoke("paste_plain_text", { text }); setEmojiOpen(false); resetPaletteState(); } : undefined}
      /></Suspense> : libraryRun ? <LibraryRunDialog entry={libraryRun.entry} action={libraryRun.action} nativeRuntime={nativeRuntime}
        onClose={() => setLibraryRun(undefined)} onComplete={(action) => { setLibraryRun(undefined); if (action === "copy") setToast(t("복사했습니다.")); else void dismissPalette(); }} />
      : scriptView ? <ScriptRunPanel script={scriptView} onBack={() => { setScriptView(undefined); requestAnimationFrame(() => inputRef.current?.focus()); }} />
      : libraryOpen ? <LibraryPanel nativeRuntime={nativeRuntime} onClose={closeLibrary} onChange={reloadLibrary} initialEntry={libraryEntry} initialTab={libraryTab} initialQuery={fileEntryQuery} initialIncludeSystem={fileEntrySystem}/> : preferencesOpen ? (
        <SettingsView
          CommandGlyph={CommandGlyph}
          preferences={preferences}
          onChange={updatePreferences}
          onClose={() => void closePreferences()}
          nativeRuntime={nativeRuntime}
          commandKey={commandKey}
          shortcut={shortcut}
          shortcutDraft={shortcutDraft}
          shortcutError={t(shortcutError)}
          shortcutBusy={shortcutBusy}
          shortcutRecording={shortcutRecording}
          onShortcutRecordingChange={(recording) => {
            setShortcutRecording(recording);
            setShortcutError("");
          }}
          onShortcutRecord={recordShortcut}
          onShortcutReset={() => void resetShortcut()}
          onToggleCommand={toggleCommand}
          maintenanceTask={maintenanceTask}
          onRefreshApplications={() => void refreshApplications()}
          onClearIconCache={() => void clearIconCache()}
          clipboardDetails={<ClipboardSettings onChanged={(state) => { setClipboardEnabledState(state.enabled); setCatalogRevision(value => value + 1); }} />}
          snippetDetails={nativeRuntime ? <SnippetExpansionSettings /> : undefined}
          backupDetails={<>
            <RaycastImport nativeRuntime={nativeRuntime} aliases={{
              read: () => readPreferences().preferences.commandAliases,
              disabled: () => readPreferences().preferences.disabledCommandIds,
              write: async commandAliases => {
                if (!updatePreferences({ ...readPreferences().preferences, commandAliases })) throw new Error(t("설정을 저장하지 못했습니다."));
              },
            }} onChanged={async () => {
              const [commands, launcher] = await Promise.all([getCommandShortcuts(), getGlobalShortcut()]);
              setCommandShortcutsState(Object.fromEntries(commands.map(command => [command.commandId, command.accelerator])));
              setShortcut(launcher); reloadLibrary();
            }} />
            {preferencesLoad.status === "malformed" && <PreferencesRecovery review={preferencesLoad.recovery}
              onReviewAgain={() => setPreferencesLoad(readPreferences())}
              onRecover={async () => {
                if (!preferencesLoad.recovery) throw new Error(t("복구할 설정이 없습니다."));
                const result = recoverPreferences(localStorage, preferencesRef.current, preferencesLoad.recovery);
                preferencesRef.current = result.preferences; setPreferences(result.preferences); setPreferencesLoad(readPreferences()); notifyLanguageChanged();
                await emitPreferencesChanged(result.preferences);
                if (!result.snapshotSaved) setToast(t("설정은 저장했지만 복구용 사본을 저장하지 못했습니다."));
              }} />}
            <BackupSettings nativeRuntime={nativeRuntime} preferences={preferences} onRestorePreferences={async safe => {
              if (preferencesLoad.status === "malformed") {
                const restored = restoreReviewedBackupPreferences(localStorage, preferencesRef.current, safe, preferencesLoad.original);
                preferencesRef.current = restored.preferences; setPreferences(restored.preferences); setPreferencesLoad(readPreferences()); notifyLanguageChanged();
                await emitPreferencesChanged(restored.preferences);
                if (!restored.snapshotSaved) setToast(t("설정은 저장했지만 복구용 사본을 저장하지 못했습니다."));
              } else if (!updatePreferences(mergeSafePreferences(preferencesRef.current, safe))) throw new Error(t("설정을 저장하지 못했습니다."));
            }} />
          </>}
          clipboardEnabled={clipboardEnabled}
          clipboardBusy={clipboardBusy}
          clipboardError={t(clipboardError)}
          onClipboardToggle={() => void toggleClipboardHistory()}
          onClipboardClear={() => void clearClipboard()}
          commandShortcuts={commandShortcuts}
          commandHotkeyRecording={commandHotkeyRecording}
          commandHotkeyBusy={commandHotkeyBusy}
          commandHotkeyError={t(commandHotkeyError || commandHotkeyRuntimeError)}
          accessibilityPermission={accessibilityPermission}
          accessibilityPermissionRequestPending={permissionPromptPending}
          accessibilityPermissionBusy={accessibilityPermissionBusy}
          accessibilityPermissionError={t(accessibilityPermissionError)}
          onAccessibilityPermissionRequest={() => void requestAccessibilityAccess()}
          onAccessibilityPermissionRefresh={() => void refreshAccessibilityPermission()}
          onAccessibilitySettingsOpen={() => void openAccessibilityPreferences()}
          onCommandAliasChange={changeCommandAlias}
          onCommandHotkeyRecordingChange={(commandId) => {
            setCommandHotkeyRecording(commandId);
            if (commandId) setCommandHotkeyError("");
          }}
          onCommandHotkeyRecord={(commandId, accelerator) => void saveCommandHotkey(commandId, accelerator)}
          onCommandHotkeyRemove={(commandId) => void deleteCommandHotkey(commandId)}
          standalone={settingsWindow}
          systemCommands={systemCommands}
          requestedNavigation={settingsNavigation}
          applicationCatalogRevision={catalogRevision}
          iconCacheRevision={iconCacheRevision}
          scriptRegistryBusy={scriptRegistryBusy}
          scriptRegistryStatus={scriptRegistryStatus}
          scriptRegistryError={t(scriptRegistryError)}
          onScriptRegistryRefresh={() => void refreshScripts()}
        />
      ) : aiOpen ? null : (
        <>
          <div className="search-zone">
            {paletteView === "clipboard" ? (
              <button className="scope-back" onClick={goBack} aria-label={t("Back to all commands")}><ArrowLeft size={17} /></button>
            ) : <PrismMark className="search-prism" />}
            <input
              ref={inputRef}
              autoFocus
              role="combobox"
              aria-label={paletteView === "clipboard" ? t("Search clipboard history") : t("Search apps and commands")}
              aria-controls="command-results"
              aria-expanded="true"
              aria-activedescendant={!loading && selectedItem ? `result-${selectedItem.id}` : undefined}
              placeholder={paletteView === "clipboard" ? t("Search Clipboard History…") : t("Search apps, commands and files…")}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              spellCheck={false}
              autoComplete="off"
            />
            <div className="search-tools">
              <button className="ai-icon-button" aria-label={t("Open AI Chat")} aria-keyshortcuts="Tab" onClick={() => setAiOpen(true)}><Sparkles size={16} /><span>AI</span></button>
              {query ? (
                <button className="clear-search" onClick={clearQuery} aria-label={t("Clear search")}>{t("Clear")}</button>
              ) : null}
            </div>
          </div>

          <div className={`workspace${paletteView === "clipboard" ? " clipboard-workspace" : ""}`}>
            {paletteView === "clipboard" && <ClipboardTypeFilter value={clipboardType} onChange={value => { setClipboardType(value); setCatalogRevision(revision => revision + 1); }} />}
            <section className="results-pane" aria-label={t("Search results")}>
              {(preferencesLoad.status === "malformed" || preferencesLoad.status === "unavailable") && <div className="provider-failure" role="alert"><span>{t("설정을 읽지 못해 임시 기본값을 사용합니다. 백업 및 복원에서 확인하세요.")}</span><button onClick={() => void openPreferences()}>{t("Settings")}</button></div>}
              {failures.map((failure) => <FailureNotice key={failure.providerId} failure={failure} onRetry={() => {
                setCatalogRevision((revision) => revision + 1);
                inputRef.current?.focus();
              }} />)}
              <div ref={resultsScrollRef} id="command-results" className={`results-scroll${answerOverview ? " answer-overview" : ""}`} role="listbox">
                {loading ? (
                  <div className="loading-state" role="status" aria-label={t("Searching")}>
                    {showLoadingIndicator ? [0, 1, 2, 3].map((value) => <span key={value} />) : null}
                  </div>
                ) : items.length ? (
                  items.map((item, index) => {
                    const subtitle = resultSubtitle(item);
                    return (
                    <div className="result-entry" key={item.id} role="presentation">
                      {!item.answer && (index === 0 || items[index - 1]?.section !== item.section) ? (
                        <div className="result-section-label">{item.section}</div>
                      ) : null}
                      <button
                        id={`result-${item.id}`}
                        tabIndex={-1}
                        ref={(element) => { resultRefs.current[index] = element; }}
                        className={`result-row ${index === selectedIndex ? "selected" : ""}${item.answer ? " instant-answer" : ""}`}
                        role="option"
                        aria-selected={index === selectedIndex}
                        aria-label={item.answer ? `${item.title}. ${item.subtitle ?? ""}` : undefined}
                        onPointerMove={(event) => {
                          if (event.movementX === 0 && event.movementY === 0) return;
                          setPointerActive(true);
                          keyboardNavigation.current = false;
                          setSelectedIndex(index);
                        }}
                        onClick={() => {
                          if (paletteView === "clipboard") { setSelectedIndex(index); inputRef.current?.focus(); }
                          else void executeAction(item.actions[0], item);
                        }}
                        onDoubleClick={paletteView === "clipboard" ? () => void executeAction(item.actions[0], item) : undefined}
                      >
                        {item.answer ? <InstantAnswer item={item} /> : (
                          <>
                            <CommandGlyph
                              item={item}
                              showApplicationIcons={preferences.showApplicationIcons}
                              cacheVersion={iconCacheRevision}
                            />
                            <span className="result-copy"><strong>{item.title}</strong>{subtitle && <small>{subtitle}</small>}</span>
                          </>
                        )}
                        {item.data?.pinned === true && <Pin className="result-favorite" size={12} aria-label={t("Pinned")}/>}
                        {item.favoriteOrder !== undefined && <Star className="result-favorite" size={12} aria-label={t("즐겨찾기")}/>}
                        {item.answer ? (
                          <span className="result-open answer-copy"><span>{item.actions[0]?.title ?? "Run"}</span></span>
                        ) : null}
                      </button>
                    </div>
                    );
                  })
                ) : (
                  <EmptyState query={query} hasFailure={failures.length > 0} clipboardView={paletteView === "clipboard"} clipboardEnabled={clipboardEnabled} />
                )}
              </div>
            </section>
            {paletteView === "clipboard" && <aside key={selectedItem?.id ?? "empty"} className="clipboard-selection-preview" aria-label={t("클립보드 미리보기")}>
              {selectedItem?.data?.historyId !== undefined ? <ClipboardEntryPreview entry={{
                id: Number(selectedItem.data.historyId), kind: (selectedItem.data.clipboardKind ?? "text") as "text" | "image" | "files",
                mimeType: String(selectedItem.data.mimeType ?? ""), content: String(selectedItem.data.previewText ?? selectedItem.title),
                capturedAt: Number(selectedItem.data.capturedAt), byteSize: Number(selectedItem.data.byteSize),
                width: Number(selectedItem.data.width), height: Number(selectedItem.data.height), fileCount: Number(selectedItem.data.fileCount),
                available: typeof selectedItem.data.available === "boolean" ? selectedItem.data.available : null,
              }} /> : <div className="clipboard-preview-empty">{t("Select an entry to preview its contents.")}</div>}
            </aside>}
            <footer className="statusbar">
              <button className="statusbar-button" onClick={() => void openPreferences()} aria-label={t("Open Settings")} title={`${t("Settings")} (${commandKey ? "⌘" : "Ctrl"} ,)`} aria-keyshortcuts={commandKey ? "Meta+," : "Control+,"}>
                <Settings size={15} strokeWidth={1.6} aria-hidden="true" />
              </button>
              <div className="statusbar-actions">
                {!loading && selectedItem?.actions[0] && (
                  <button className="statusbar-button statusbar-primary" disabled={actionsOpen} onClick={() => void executeAction(selectedItem.actions[0], selectedItem)}>
                    <span>{selectedItem.actions[0].title}</span><span aria-hidden="true"><Shortcut keys={["↵"]} /></span>
                  </button>
                )}
                <button className="statusbar-button" onClick={actionsOpen ? closeActions : openActions} disabled={!selectedItem || loading} aria-label={t("Open actions")} title={`${t("Open actions")} (${commandKey ? "⌘" : "Ctrl"} K)`} aria-keyshortcuts={commandKey ? "Meta+K" : "Control+K"} aria-haspopup="dialog" aria-expanded={actionsOpen}>
                  <span>{t("Actions")}</span><span aria-hidden="true"><Shortcut keys={["⌘", "K"]} /></span>
                </button>
              </div>
            </footer>
          </div>
        </>
      )}



      {actionItem ? (
        <ActionPanel
          item={actionItem}
          actions={filteredActions}
          query={actionQuery}
          onQueryChange={(value) => { setActionQuery(value); setActionIndex(0); }}
          activeIndex={actionIndex}
          onActive={setActionIndex}
          onSelect={(action) => void executeAction(action, actionItem)}
          onClose={closeActions}
        />
      ) : null}
      <div className={`toast ${toast ? "visible" : ""}`} role="status" aria-live="polite">{t(toast)}</div>
    </main>
  );
}
