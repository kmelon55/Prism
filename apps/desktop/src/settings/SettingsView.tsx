import { InterfaceMotion } from "./InterfaceMotion";
import { SettingsSelect } from "./SettingsSelect";
import { Updates } from "../Updates";
import { useEffect, useLayoutEffect, useRef, useState, useId, type ComponentType, type ReactNode } from "react";
import { ArrowLeft, Check, Clipboard, ExternalLink, FolderOpen, MoonStar, Plus, RefreshCw, Search, ShieldCheck, Sun, SunMoon, Terminal, Trash2, TriangleAlert, X, type LucideIcon } from "lucide-react";
import type { CommandDefinition, CommandItem } from "@prism/command-core";
import { t, bilingual, useLocale, type Language } from "../i18n";
import { PermissionRuntimeDetails } from "./PermissionRuntimeDetails";
import { PrismMark } from "../PrismMark";
import { ShortcutCapture, doubleShortcutKeys, useShortcutCaptureLease } from "./shortcutCapture";
import { AnimationSettings } from "./AnimationSettings";
import { MAX_BACKGROUND_BLUR } from "./appearance";
import { AiSettings } from "../AiSettings";
import { DictationSettings, DictationPermissions } from "../dictation/DictationSettings";
import { getNativeApplication, searchNativeApplications, nativeApplicationCommandId, nativeApplicationItem, type AccessibilityPermissionStatus, type NativeApplication, type NativeSettingsNavigationRequest } from "../providers/native";
import type { GlobalShortcutSetting } from "../providers/shortcut";
import { prismCommandDefinitions, prismCommandIds } from "../providers/prism";
import { preferenceSections, settingsNavigationGroups, matchesSettingsSearch } from "./settingsNavigation";

export type ThemePreference = "system" | "dark" | "light";

export interface SettingsPreferences {
  language: Language;
  theme: ThemePreference;
  reduceMotion: boolean;
  openingLightAnimation?: boolean;
  reflectionIntensity?: number;
  reflectionEdge?: number;
  reflectionHighlight?: number;
  reflectionSpeed?: number;
  backgroundOpacity: number;
  backgroundBlur: number;
  showApplicationIcons: boolean;
  disabledCommandIds: string[];
  commandAliases: Record<string, string>;
  scriptDirectories: string[];
}

export type PreferencesSection = "dictation" | "snippets" | "backup" | "ai" | "general" | "applications" | "scripts" | "clipboard" | "shortcut" | "permissions" | "window-management" | "commands";

export interface SettingsViewProps {
  clipboardDetails?: ReactNode;
  backupDetails?: ReactNode;
  snippetDetails?: ReactNode;
  preferences: SettingsPreferences;
  onChange: (next: SettingsPreferences) => void;
  onClose: () => void;
  nativeRuntime: boolean;
  commandKey: boolean;
  shortcut: GlobalShortcutSetting;
  shortcutDraft: string;
  shortcutError: string;
  shortcutBusy: boolean;
  shortcutRecording: boolean;
  onShortcutRecordingChange: (recording: boolean) => void;
  onShortcutRecord: (accelerator: string) => void;
  onShortcutSave: () => void;
  onShortcutReset: () => void;
  onToggleCommand: (commandId: string) => void;
  maintenanceTask?: "refresh" | "clear";
  onRefreshApplications: () => void;
  onClearIconCache: () => void;
  clipboardEnabled: boolean;
  clipboardBusy: boolean;
  clipboardError: string;
  onClipboardToggle: () => void;
  onClipboardClear: () => void;
  commandShortcuts: Record<string, string>;
  commandHotkeyRecording?: string;
  commandHotkeyBusy?: string;
  commandHotkeyError: string;
  accessibilityPermission: AccessibilityPermissionStatus;
  accessibilityPermissionRequestPending?: boolean;
  accessibilityPermissionBusy: boolean;
  accessibilityPermissionError: string;
  onAccessibilityPermissionRequest: () => void;
  onAccessibilityPermissionRefresh: () => void;
  onAccessibilitySettingsOpen: () => void;
  onCommandAliasChange: (commandId: string, alias: string) => void;
  onCommandHotkeyRecordingChange: (commandId?: string) => void;
  onCommandHotkeyRecord: (commandId: string, accelerator: string) => void;
  onCommandHotkeyRemove: (commandId: string) => void;
  standalone: boolean;
  systemCommands: readonly CommandDefinition[];
  requestedNavigation?: NativeSettingsNavigationRequest;
  applicationCatalogRevision: number;
  iconCacheRevision: number;
  scriptRegistryBusy: boolean;
  scriptRegistryStatus: string;
  scriptRegistryError: string;
  onScriptRegistryRefresh: () => void;
  CommandGlyph: ComponentType<{ item: CommandItem; showApplicationIcons: boolean; cacheVersion: number }>;
}

function formatShortcutToken(token: string, commandKey: boolean): string {
  const normalized = token.toLowerCase();
  if (normalized === "super" || normalized === "command" || normalized === "cmd") {
    return commandKey ? "⌘" : "Super";
  }
  if (normalized === "control" || normalized === "ctrl") return commandKey ? "⌃" : "Ctrl";
  if (normalized === "shift") return "⇧";
  if (normalized === "alt" || normalized === "option") return commandKey ? "⌥" : "Alt";
  if (normalized === "space") return "Space";
  if (/^key[a-z]$/i.test(token)) return token.slice(3).toUpperCase();
  if (/^digit\d$/i.test(token)) return token.slice(5);
  return token.replace(/^Arrow/, "");
}

function acceleratorKeys(accelerator: string, commandKey: boolean): string[] {
  const double = doubleShortcutKeys(accelerator);
  if (double) return double;
  const tokens = accelerator.split("+").map((token) => token.trim()).filter(Boolean);
  const modifiers = new Map(tokens.slice(0, -1).map((token) => [token.toLowerCase(), token]));
  const order = commandKey
    ? ["super", "shift", "alt", "control"]
    : ["control", "shift", "alt", "super"];
  const keys = order
    .map((modifier) => modifiers.get(modifier))
    .filter((token): token is string => Boolean(token))
    .map((token) => formatShortcutToken(token, commandKey));
  const key = tokens.at(-1);
  if (key) keys.push(formatShortcutToken(key, commandKey));
  return keys;
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

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message) return error.message;
  if (error && typeof error === "object" && "message" in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string" && message) return message;
  }
  if (typeof error === "string" && error) return error;
  return fallback;
}

const hiddenMaintenanceCommandIds = new Set<string>([
  prismCommandIds.refreshApplications,
  prismCommandIds.clearIconCache,
  prismCommandIds.clearClipboardHistory,
]);

export function SettingsView(props: SettingsViewProps) {
  useLocale();
  const {
    CommandGlyph,
    clipboardDetails,
    backupDetails,
    snippetDetails,
    preferences,
    onChange,
    onClose,
    nativeRuntime,
    commandKey,
    shortcut,
    shortcutDraft,
    shortcutError,
    shortcutBusy,
    shortcutRecording,
    onShortcutRecordingChange,
    onShortcutRecord,
    onShortcutSave,
    onShortcutReset,
    onToggleCommand,
    maintenanceTask,
    onRefreshApplications,
    onClearIconCache,
    clipboardEnabled,
    clipboardBusy,
    clipboardError,
    onClipboardToggle,
    onClipboardClear,
    commandShortcuts,
    commandHotkeyRecording,
    commandHotkeyBusy,
    commandHotkeyError,
    accessibilityPermission,
    accessibilityPermissionRequestPending = false,
    accessibilityPermissionBusy,
    accessibilityPermissionError,
    onAccessibilityPermissionRequest,
    onAccessibilityPermissionRefresh,
    onAccessibilitySettingsOpen,
    onCommandAliasChange,
    onCommandHotkeyRecordingChange,
    onCommandHotkeyRecord,
    onCommandHotkeyRemove,
    standalone,
    systemCommands,
    requestedNavigation,
    applicationCatalogRevision,
    iconCacheRevision,
    scriptRegistryBusy,
    scriptRegistryStatus,
    scriptRegistryError,
    onScriptRegistryRefresh,
  } = props;
  const headingId = useId();
  const [settingsQuery, setSettingsQuery] = useState("");
  const [searchSelection, setSearchSelection] = useState<PreferencesSection>();
  const [section, setSection] = useState<PreferencesSection>("general");
  const [confirmClipboardClear, setConfirmClipboardClear] = useState(false);
  const [confirmIconClear, setConfirmIconClear] = useState(false);
  const [applicationQuery, setApplicationQuery] = useState("");
  const [applicationResults, setApplicationResults] = useState<NativeApplication[]>([]);
  const [applicationsBusy, setApplicationsBusy] = useState(false);
  const [applicationsError, setApplicationsError] = useState("");
  const [scriptDirectoryDraft, setScriptDirectoryDraft] = useState("");
  const settingsRef = useRef<HTMLElement>(null);
  const confirmationRef = useRef<"clipboard" | "icons" | undefined>(undefined);
  useLayoutEffect(() => {
    settingsRef.current?.querySelector<HTMLElement>("nav button")?.focus();
  }, []);
  useLayoutEffect(() => {
    const scope = confirmClipboardClear ? "clipboard" : confirmIconClear ? "icons" : undefined;
    const selector = scope ? `[data-confirm-${scope}]`
      : confirmationRef.current ? `[data-clear-${confirmationRef.current}]` : undefined;
    if (selector) settingsRef.current?.querySelector<HTMLElement>(selector)?.focus();
    confirmationRef.current = scope;
  }, [confirmClipboardClear, confirmIconClear]);
  const themes: Array<{ value: ThemePreference; title: string; icon: LucideIcon }> = [
    { value: "system", title: t("System"), icon: SunMoon },
    { value: "dark", title: t("Dark"), icon: MoonStar },
    { value: "light", title: t("Light"), icon: Sun },
  ];
  const visiblePreferenceSections = nativeRuntime
    ? preferenceSections
    : preferenceSections.filter((entry) => entry.id !== "applications" && entry.id !== "scripts");
  const windowCommands = prismCommandDefinitions.filter((command) => command.id.startsWith("window:"));
  const otherCommands = [
    ...prismCommandDefinitions.filter(
      (command) =>
        !command.id.startsWith("window:") && !hiddenMaintenanceCommandIds.has(command.id),
    ),
    ...systemCommands,
  ];
  const filteredSections = visiblePreferenceSections.filter((entry) => matchesSettingsSearch(entry, settingsQuery,
    entry.id === "commands" ? otherCommands.map((command) => command.title)
      : entry.id === "window-management" ? windowCommands.map((command) => command.title) : []));
  const normalizedQuery = settingsQuery.normalize("NFKC").trim().toLocaleLowerCase();
  const bestSection = filteredSections.find(entry => bilingual(entry.label).some(label => label.normalize("NFKC").toLocaleLowerCase() === normalizedQuery)) ?? filteredSections[0];
  const preferredSection = normalizedQuery ? searchSelection : section;
  const activeSection = filteredSections.some((entry) => entry.id === preferredSection) ? preferredSection : bestSection?.id;
  const currentSection = filteredSections.find((entry) => entry.id === activeSection);
  const shortcutKeys = acceleratorKeys(shortcutDraft || shortcut.accelerator, commandKey);

  const stopRecorders = () => {
    onShortcutRecordingChange(false);
    onCommandHotkeyRecordingChange(undefined);
    setConfirmClipboardClear(false);
    setConfirmIconClear(false);
  };

  const shortcutCapture = useRef(new ShortcutCapture());
  const captureLease = useShortcutCaptureLease(nativeRuntime, shortcutRecording || !!commandHotkeyRecording, "settings", stopRecorders);
  useEffect(() => { shortcutCapture.current.reset(); }, [shortcutRecording, commandHotkeyRecording]);
  const captureKeyUp = (event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (!shortcutRecording && !commandHotkeyRecording) return;
    event.preventDefault(); event.stopPropagation(); shortcutCapture.current.keyup(event.nativeEvent);
  };

  useEffect(() => {
    if (!confirmClipboardClear) return;
    const timer = window.setTimeout(() => setConfirmClipboardClear(false), 5000);
    return () => window.clearTimeout(timer);
  }, [confirmClipboardClear]);

  useEffect(() => {
    if (!confirmIconClear) return;
    const timer = window.setTimeout(() => setConfirmIconClear(false), 5000);
    return () => window.clearTimeout(timer);
  }, [confirmIconClear]);

  useEffect(() => {
    if (requestedNavigation) setSettingsQuery("");
    if (requestedNavigation?.section === "ai") { setSection("ai"); return; }
    if (!requestedNavigation || requestedNavigation.section !== "applications") return;
    setSection("applications");
    if (requestedNavigation.applicationName) {
      setApplicationQuery(requestedNavigation.applicationName);
      return;
    }
    if (!requestedNavigation.applicationId) return;
    let active = true;
    void getNativeApplication(requestedNavigation.applicationId)
      .then((application) => {
        if (active && application) setApplicationQuery(application.name);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [requestedNavigation]);

  useEffect(() => {
    if (!nativeRuntime || activeSection !== "applications") return;
    let active = true;
    const timer = window.setTimeout(() => {
      setApplicationsBusy(true);
      setApplicationsError("");
      void searchNativeApplications(applicationQuery, applicationQuery.trim() ? 100 : 40)
        .then((applications) => {
          if (!active) return;
          setApplicationResults(applications);
        })
        .catch((error) => {
          if (!active) return;
          setApplicationResults([]);
          setApplicationsError(errorMessage(error, t("Installed applications could not be loaded.")));
        })
        .finally(() => {
          if (active) setApplicationsBusy(false);
        });
    }, 120);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [applicationCatalogRevision, applicationQuery, nativeRuntime, activeSection]);

  const recordLauncherShortcut = (event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (!captureLease.ready || !shortcutRecording || event.repeat || event.nativeEvent.isComposing || event.keyCode === 229) return;
    event.preventDefault();
    event.stopPropagation();
    if (event.key === "Escape") {
      onShortcutRecordingChange(false);
      return;
    }
    const accelerator = shortcutCapture.current.keydown(event.nativeEvent);
    if (accelerator !== undefined) onShortcutRecord(accelerator);
  };

  const renderCommandRow = (command: CommandDefinition) => {
    const promptOnly = activeSection === "dictation" && command.id === prismCommandIds.dictationPrompt;
    const enabled = !preferences.disabledCommandIds.includes(command.id);
    const commandShortcut = commandShortcuts[command.id] ?? "";
    const recording = commandHotkeyRecording === command.id;
    const item: CommandItem = {
      ...command,
      providerId: command.id.startsWith("system:") ? "system" : "prism",
    };

    return (
      <div className="settings-command-row" key={command.id} role="group" aria-label={t(command.title)}>
        <CommandGlyph
          item={item}
          showApplicationIcons={preferences.showApplicationIcons}
          cacheVersion={iconCacheRevision}
        />
        <span className="settings-command-name">{t(command.title)}</span>
        <input
          className="command-alias-input"
          aria-label={t("Alias for {0}", {"0": command.title})}
          placeholder={t("Add alias")}
          value={preferences.commandAliases[command.id] ?? ""}
          maxLength={80}
          onChange={(event) => onCommandAliasChange(command.id, event.target.value)}
        />
        <div className="settings-command-actions">
          <button
            className={`command-hotkey ${recording ? "recording" : ""}`}
            aria-label={t("Global shortcut for {0}", {"0": command.title})}
            aria-pressed={recording}
            disabled={!nativeRuntime || !enabled || commandHotkeyBusy === command.id}
            onClick={(event) => { event.currentTarget.focus(); onCommandHotkeyRecordingChange(recording ? undefined : command.id); }}
            title={t("조합 키를 누르거나 보조 키를 두 번 누르세요.")}
            onKeyUp={captureKeyUp}
            onBlur={() => { shortcutCapture.current.reset(); onCommandHotkeyRecordingChange(undefined); }}
            onKeyDown={(event) => {
              if (!captureLease.ready || !recording || event.repeat || event.nativeEvent.isComposing || event.keyCode === 229) return;
              event.preventDefault();
              event.stopPropagation();
              if (event.key === "Escape") {
                onCommandHotkeyRecordingChange(undefined);
                return;
              }
              const accelerator = shortcutCapture.current.keydown(event.nativeEvent);
              if (accelerator !== undefined) onCommandHotkeyRecord(command.id, accelerator);
            }}
          >
            {recording ? <span>{t("키 조합 / 보조 키 두 번…")}</span> : commandShortcut ? (
              <Shortcut keys={acceleratorKeys(commandShortcut, commandKey)} />
            ) : <span>{t("Record Hotkey")}</span>}
          </button>
          {commandShortcut ? (
            <button
              className="command-hotkey-remove"
              aria-label={t("Remove shortcut for {0}", {"0": command.title})}
              disabled={commandHotkeyBusy === command.id}
              onClick={() => onCommandHotkeyRemove(command.id)}
            ><X size={13} /></button>
          ) : null}
          {(!promptOnly || !enabled) && <button
            className={`switch ${enabled ? "active" : ""}`}
            role="switch"
            aria-label={`${enabled ? t("Disable") : t("Enable")} ${t(command.title)}`}
            aria-checked={enabled}
            disabled={!command.management.canDisable}
            onClick={() => onToggleCommand(command.id)}
          ><span /></button>}
        </div>
      </div>
    );
  };

  const renderApplicationRow = (application: NativeApplication) => {
    const commandId = nativeApplicationCommandId(application.id);
    const enabled = !preferences.disabledCommandIds.includes(commandId);
    const commandShortcut = commandShortcuts[commandId] ?? "";
    const recording = commandHotkeyRecording === commandId;
    const item = nativeApplicationItem(application);

    return (
      <div className="settings-command-row" key={application.id} role="group" aria-label={application.name}>
        <CommandGlyph
          item={item}
          showApplicationIcons={preferences.showApplicationIcons}
          cacheVersion={iconCacheRevision}
        />
        <span className="settings-command-copy">
          <strong>{application.name}</strong>
          <small>{application.path}</small>
        </span>
        <input
          className="command-alias-input"
          aria-label={t("Alias for {0}", {"0": application.name})}
          placeholder={t("Add alias")}
          value={preferences.commandAliases[commandId] ?? ""}
          maxLength={80}
          onChange={(event) => onCommandAliasChange(commandId, event.target.value)}
        />
        <div className="settings-command-actions">
          <button
            className={`command-hotkey ${recording ? "recording" : ""}`}
            aria-label={t("Global shortcut for {0}", {"0": application.name})}
            aria-pressed={recording}
            disabled={!enabled || commandHotkeyBusy === commandId}
            onClick={(event) => { event.currentTarget.focus(); onCommandHotkeyRecordingChange(recording ? undefined : commandId); }}
            title={t("조합 키를 누르거나 보조 키를 두 번 누르세요.")}
            onKeyUp={captureKeyUp}
            onBlur={() => { shortcutCapture.current.reset(); onCommandHotkeyRecordingChange(undefined); }}
            onKeyDown={(event) => {
              if (!captureLease.ready || !recording || event.repeat || event.nativeEvent.isComposing || event.keyCode === 229) return;
              event.preventDefault();
              event.stopPropagation();
              if (event.key === "Escape") {
                onCommandHotkeyRecordingChange(undefined);
                return;
              }
              const accelerator = shortcutCapture.current.keydown(event.nativeEvent);
              if (accelerator !== undefined) onCommandHotkeyRecord(commandId, accelerator);
            }}
          >
            {recording ? <span>{t("키 조합 / 보조 키 두 번…")}</span> : commandShortcut ? (
              <Shortcut keys={acceleratorKeys(commandShortcut, commandKey)} />
            ) : <span>{t("Record Hotkey")}</span>}
          </button>
          {commandShortcut ? (
            <button
              className="command-hotkey-remove"
              aria-label={t("Remove shortcut for {0}", {"0": application.name})}
              disabled={commandHotkeyBusy === commandId}
              onClick={() => onCommandHotkeyRemove(commandId)}
            ><X size={13} /></button>
          ) : null}
          <button
            className={`switch ${enabled ? "active" : ""}`}
            role="switch"
            aria-label={`${enabled ? t("Disable") : t("Enable")} ${application.name}`}
            aria-checked={enabled}
            onClick={() => onToggleCommand(commandId)}
          ><span /></button>
        </div>
      </div>
    );
  };

  const addScriptDirectory = () => {
    const directory = scriptDirectoryDraft.trim();
    if (!directory || preferences.scriptDirectories.includes(directory)) return;
    onChange({
      ...preferences,
      scriptDirectories: [...preferences.scriptDirectories, directory],
    });
    setScriptDirectoryDraft("");
  };

  return (
    <InterfaceMotion reducedMotion={preferences.reduceMotion}><section
      className="preferences-view preferences-v2"
      ref={settingsRef}
      role={standalone ? "region" : "dialog"}
      aria-modal={standalone ? undefined : "true"}
      aria-label={t("Prism settings")}
      onKeyDown={(event) => {
        if (event.nativeEvent.isComposing || event.keyCode === 229 || event.key !== "Escape") return;
        event.preventDefault();
        event.stopPropagation();
        if (event.repeat) return;
        if (confirmClipboardClear || confirmIconClear) {
          setConfirmClipboardClear(false);
          setConfirmIconClear(false);
        } else {
          onClose();
        }
      }}
    >
      <aside className="settings-sidebar">
        <div className="settings-brand">
          <PrismMark />
          <div className="settings-brand-copy"><strong>PRISM</strong></div>
        </div>
        <label className="settings-filter settings-search">
          <Search size={15} aria-hidden="true" />
          <span className="sr-only">{t("Search settings")}</span>
          <input type="search" value={settingsQuery} placeholder={t("Search settings…")}
            aria-label={t("Search settings")}
            onChange={(event) => { setSettingsQuery(event.target.value); setSearchSelection(undefined); stopRecorders(); }}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing || event.keyCode === 229) return;
              if (event.key === "Escape" && settingsQuery) {
                event.preventDefault(); event.stopPropagation(); setSettingsQuery("");
              }
            }} />
        </label>
        <nav aria-label={t("Settings sections")}>
          {settingsNavigationGroups.map((group) => {
            const entries = filteredSections.filter((entry) => group.sections.includes(entry.id));
            if (!entries.length) return null;
            return <div className="settings-nav-group" key={group.label} role="group" aria-label={t(group.label)}>
              <h3 className="settings-nav-group-title">{t(group.label)}</h3>
              {entries.map(({ id, label, icon: Icon }) => (
                <button key={id} className={activeSection === id ? "active" : ""}
                  aria-current={activeSection === id ? "page" : undefined}
                  onClick={() => { if (settingsQuery.trim()) setSearchSelection(id); else setSection(id); stopRecorders(); }}>
                  <Icon size={16} strokeWidth={1.8} aria-hidden="true" /><span>{t(label)}</span>
                </button>
              ))}
            </div>;
          })}
        </nav>
        {settingsQuery.trim() ? <p className="settings-search-status" role="status">
          {filteredSections.length ? t("{0} settings sections found", {0: filteredSections.length}) : t("No settings found")}
        </p> : null}
        {!standalone ? (
          <button className="settings-back" onClick={onClose}><ArrowLeft size={15} /> {t("Back to Prism")}</button>
        ) : null}
      </aside>

      <div className="settings-content">
        <header className="settings-header">
          <div className="settings-title">
            <div><span className="settings-context">Prism</span><h2 id={headingId}>{currentSection ? t(currentSection.label) : t("No settings found")}</h2><p>{currentSection ? t(currentSection.description) : t("Try another setting name or keyword.")}</p></div>
          </div>
          {!standalone ? <button className="icon-button" onClick={onClose} aria-label={t("Close settings")}><X size={16} /></button> : null}
        </header>

        <div className="settings-scroll" role="region" aria-labelledby={headingId}>
          {captureLease.error && <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(captureLease.error)}</span></div>}
          {activeSection === "snippets" ? snippetDetails ?? <p className="preference-note">{t("자동 확장은 데스크톱 앱에서 설정할 수 있습니다.")}</p> : null}
          {activeSection === "backup" ? backupDetails ?? <p className="preference-note">{t("Backup and restore are available in the desktop app.")}</p> : null}
          {activeSection === "ai" ? <AiSettings nativeRuntime={nativeRuntime} /> : null}
          {activeSection === "dictation" ? <DictationSettings nativeRuntime={nativeRuntime}
            shortcut={<>{prismCommandDefinitions.filter(command => command.id === prismCommandIds.dictation).map(renderCommandRow)}
              {commandHotkeyError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(commandHotkeyError)}</span></div> : null}</>}
            promptShortcut={<>{prismCommandDefinitions.filter(command => command.id === prismCommandIds.dictationPrompt).map(renderCommandRow)}</>}
            onAiSettings={() => { setSettingsQuery(""); setSection("ai"); stopRecorders(); }}
            onPermissions={() => { setSettingsQuery(""); setSection("permissions"); stopRecorders(); }} /> : null}
          {activeSection === "general" ? (
            <>
              <Updates />
              <div className="settings-group" role="group" aria-label={t("Language")}>
                <div className="settings-row">
                  <div className="preference-copy"><strong>{t("Language")}</strong></div>
                  <SettingsSelect label={t("App language")} value={preferences.language} onChange={value => onChange({...preferences,language:value as Language})} options={[{value:"system",label:t("Follow system")},{value:"ko",label:"한국어"},{value:"en",label:"English"}]} />
                </div>
              </div>
              <div className="settings-group" role="group" aria-label={t("Appearance")}>
                <h3 className="settings-group-title">{t("Appearance")}</h3>
                <div className="settings-row settings-row-stack">
                  <div className="preference-copy"><strong>{t("Theme")}</strong><span>{t("Match the system or keep one appearance.")}</span></div>
                  <div className="theme-options" role="radiogroup" aria-label={t("Appearance")}
                    onKeyDown={(event) => {
                      if (event.nativeEvent.isComposing || event.keyCode === 229) return;
                      const current = themes.findIndex((theme) => theme.value === preferences.theme);
                      const next = event.key === "Home" ? 0 : event.key === "End" ? themes.length - 1
                        : ["ArrowRight", "ArrowDown"].includes(event.key) ? (current + 1) % themes.length
                        : ["ArrowLeft", "ArrowUp"].includes(event.key) ? (current + themes.length - 1) % themes.length : undefined;
                      if (next === undefined) return;
                      event.preventDefault(); event.stopPropagation();
                      onChange({ ...preferences, theme: themes[next].value });
                      event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="radio"]')[next]?.focus();
                    }}>
                    {themes.map(({ value, title, icon: Icon }) => (
                      <button key={value} role="radio" tabIndex={preferences.theme === value ? 0 : -1} aria-checked={preferences.theme === value} className={preferences.theme === value ? "active" : ""} onClick={() => onChange({ ...preferences, theme: value })}>
                        <Icon size={14} /><span>{t(title)}</span>{preferences.theme === value ? <Check size={14} /> : null}
                      </button>
                    ))}
                  </div>
                </div>
                <div className="settings-row">
                  <div className="preference-copy"><strong>{t("Background opacity")}</strong><span>{t("Keep content clear over any desktop.")}</span></div>
                  <label className="range-control"><input type="range" min="10" max="100" value={preferences.backgroundOpacity} aria-label={t("Background opacity")} onChange={(event) => onChange({ ...preferences, backgroundOpacity: Number(event.target.value) })} /><span className="range-value">{preferences.backgroundOpacity}%</span></label>
                </div>
                <div className="settings-row">
                  <div className="preference-copy"><strong>{t("Background blur")}</strong><span>{t("Blur background details while keeping their colors.")}</span></div>
                  <label className="range-control"><input type="range" min="0" max={MAX_BACKGROUND_BLUR} step="1" value={preferences.backgroundBlur} aria-label={t("Background blur")} onChange={(event) => onChange({ ...preferences, backgroundBlur: Number(event.target.value) })} /><span className="range-value">{preferences.backgroundBlur}{nativeRuntime ? "" : "px"}</span></label>
                </div>
              </div>
              <div className="settings-group" role="group" aria-label={t("Behavior")}>
                <h3 className="settings-group-title">{t("Behavior")}</h3>
                <div className="settings-row"><div className="preference-copy"><strong>{t("Application icons")}</strong><span>{t("Show recognizable native app icons in results.")}</span></div><button className={`switch ${preferences.showApplicationIcons ? "active" : ""}`} role="switch" aria-label={t("Show application icons")} aria-checked={preferences.showApplicationIcons} onClick={() => onChange({ ...preferences, showApplicationIcons: !preferences.showApplicationIcons })}><span /></button></div>
                <AnimationSettings preferences={preferences} onChange={onChange} />
              </div>
              {nativeRuntime ? (
                <div className="settings-group" role="group" aria-label={t("Application index")}>
                <h3 className="settings-group-title">{t("Application index")}</h3>
                  <div className="settings-row"><div className="preference-copy"><strong>{t("Installed applications")}</strong><span>{t("Refresh apps or clear locally cached icons.")}</span></div><div className="preference-actions"><button disabled={Boolean(maintenanceTask)} onClick={onRefreshApplications}><RefreshCw className={maintenanceTask === "refresh" ? "spinning" : ""} size={14} />{t("Refresh")}</button>{confirmIconClear ? <><button className="danger-action" disabled={Boolean(maintenanceTask)} data-confirm-icons onClick={() => { setConfirmIconClear(false); onClearIconCache(); }}><Trash2 size={14} />{t("Confirm Clear")}</button><button onClick={() => setConfirmIconClear(false)}>{t("Cancel")}</button></> : <button disabled={Boolean(maintenanceTask)} data-clear-icons onClick={() => setConfirmIconClear(true)}><Trash2 size={14} />{t("Clear Icons")}</button>}</div></div>
                </div>
              ) : null}
            </>
          ) : null}

          {activeSection === "applications" ? (
            <>
              <div className="settings-toolbar">
                <label className="settings-filter">
                  <Search size={15} aria-hidden="true" />
                  <span className="sr-only">{t("Search installed applications")}</span>
                  <input
                    value={applicationQuery}
                    onChange={(event) => setApplicationQuery(event.target.value)}
                    placeholder={t("Search installed applications…")}
                    aria-label={t("Search installed applications")}
                  />
                </label>
                <button
                  className="settings-toolbar-button"
                  disabled={Boolean(maintenanceTask)}
                  onClick={onRefreshApplications}
                  aria-label={t("Refresh installed applications")}
                >
                  <RefreshCw className={maintenanceTask === "refresh" ? "spinning" : ""} size={14} />
                  {t("Refresh")}</button>
              </div>
              <div className="window-intro">
                <div><strong>{t("Installed applications")}</strong><span>{t("Aliases affect Prism search. App hotkeys resolve the current indexed path before launch.")}</span></div>
                <span className="settings-count">{applicationsBusy ? t("Searching…") : t("{0} shown", {0: applicationResults.length})}</span>
              </div>
              <div className="settings-command-table application-command-table">
                <div className="settings-command-head"><span>{t("Application")}</span><span>{t("Alias")}</span><span>{t("Hotkey")}</span></div>
                {applicationResults.map(renderApplicationRow)}
                {!applicationsBusy && !applicationResults.length ? (
                  <div className="settings-table-empty">{t("No installed applications match this search.")}</div>
                ) : null}
              </div>
              {applicationsError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(applicationsError)}</span></div> : null}
              {commandHotkeyError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(commandHotkeyError)}</span></div> : null}
            </>
          ) : null}

          {activeSection === "scripts" ? (
            <>
              <div className="settings-group" role="group" aria-label={t("Local directories")}>
                <h3 className="settings-group-title">{t("Local directories")}</h3>
                <div className="settings-row settings-row-stack">
                  <div className="preference-copy"><strong>{t("Script command folders")}</strong><span>{t("Add absolute local directories, then refresh explicitly to rebuild the safe native registry.")}</span></div>
                  <div className="script-directory-editor">
                    <input
                      value={scriptDirectoryDraft}
                      onChange={(event) => setScriptDirectoryDraft(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" && !event.nativeEvent.isComposing && event.keyCode !== 229) {
                          event.preventDefault();
                          addScriptDirectory();
                        }
                      }}
                      placeholder="/Users/you/Scripts"
                      aria-label={t("Local script directory")}
                    />
                    <button
                      disabled={!scriptDirectoryDraft.trim() || preferences.scriptDirectories.length >= 32}
                      onClick={addScriptDirectory}
                    ><Plus size={14} />{t("Add Directory")}</button>
                  </div>
                </div>
                {preferences.scriptDirectories.length ? (
                  <div className="script-directory-list" aria-label={t("Configured script directories")}>
                    {preferences.scriptDirectories.map((directory) => (
                      <div className="script-directory-row" key={directory}>
                        <FolderOpen size={15} aria-hidden="true" />
                        <span title={directory}>{directory}</span>
                        <button
                          aria-label={t("Remove script directory {0}", {"0": directory})}
                          onClick={() => onChange({
                            ...preferences,
                            scriptDirectories: preferences.scriptDirectories.filter((entry) => entry !== directory),
                          })}
                        ><X size={13} /></button>
                      </div>
                    ))}
                  </div>
                ) : (
                  <div className="settings-table-empty">{t("No script directories configured.")}</div>
                )}
              </div>
              <div className="settings-group" role="group" aria-label={t("Command registry")}>
                <h3 className="settings-group-title">{t("Command registry")}</h3>
                <div className="settings-row">
                  <div className="preference-copy"><strong>{t("Registry status")}</strong><span>{scriptRegistryStatus}</span></div>
                  <button
                    className="settings-toolbar-button"
                    disabled={scriptRegistryBusy}
                    onClick={onScriptRegistryRefresh}
                    aria-label={t("Refresh script commands")}
                  ><RefreshCw className={scriptRegistryBusy ? "spinning" : ""} size={14} />{t("Refresh Commands")}</button>
                </div>
              </div>
              {scriptRegistryError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(scriptRegistryError)}</span></div> : null}
              <div className="settings-callout"><Terminal size={17} /><div><strong>{t("Local and explicit")}</strong><span>{t("Prism refreshes once at startup and only runs scripts already present in the current native registry.")}</span></div></div>
            </>
          ) : null}

          {activeSection === "clipboard" ? (
            clipboardDetails ?? <>
              <div className="settings-group" role="group" aria-label={t("History")}>
                <h3 className="settings-group-title">{t("History")}</h3>
                <div className="settings-row"><div className="preference-copy"><strong>{t("Clipboard history")}</strong><span>{t("Store copied text locally so it can appear in Prism.")}</span></div><button className={`switch ${clipboardEnabled ? "active" : ""}`} role="switch" aria-label={t("Enable clipboard history")} aria-checked={clipboardEnabled} disabled={!nativeRuntime || clipboardBusy} onClick={onClipboardToggle}><span /></button></div>
                <div className="settings-row"><div className="preference-copy"><strong>{t("Clear history")}</strong><span>{t("Delete every stored entry from this device.")}</span></div><div className="preference-actions">{confirmClipboardClear ? <><button className="danger-action" disabled={!nativeRuntime || clipboardBusy} data-confirm-clipboard onClick={() => { setConfirmClipboardClear(false); onClipboardClear(); }}><Trash2 size={14} />{t("Confirm Clear")}</button><button onClick={() => setConfirmClipboardClear(false)}>{t("Cancel")}</button></> : <button disabled={!nativeRuntime || clipboardBusy} data-clear-clipboard onClick={() => setConfirmClipboardClear(true)}><Trash2 size={14} />{t("Clear History")}</button>}</div></div>
              </div>
              <div className="settings-callout"><Clipboard size={17} /><div><strong>{t("Private by default")}</strong><span>{t("History is opt-in, local-only, and never needs a network connection.")}</span></div></div>
              {clipboardError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(clipboardError)}</span></div> : null}
            </>
          ) : null}

          {activeSection === "shortcut" ? (
            <>
              <div className="settings-group" role="group" aria-label={t("Global hotkey")}>
                <h3 className="settings-group-title">{t("Global hotkey")}</h3>
                <div className="settings-row"><div className="preference-copy"><strong>{t("Open or hide Prism")}</strong><span>{t("Use one shortcut from anywhere on your desktop.")}</span></div><div className="shortcut-editor"><button className={`shortcut-recorder ${shortcutRecording ? "recording" : ""}`} aria-pressed={shortcutRecording} disabled={!nativeRuntime || shortcutBusy} onClick={(event) => { event.currentTarget.focus(); onShortcutRecordingChange(!shortcutRecording); }} title={t("조합 키를 누르거나 보조 키를 두 번 누르세요.")} onBlur={() => { shortcutCapture.current.reset(); onShortcutRecordingChange(false); }} onKeyUp={captureKeyUp} onKeyDown={recordLauncherShortcut}>{shortcutRecording ? <span>{t("키 조합 / 보조 키 두 번…")}</span> : <Shortcut keys={shortcutKeys} />}</button><span className={`shortcut-status ${nativeRuntime && shortcut.registered ? "ready" : ""}`}>{nativeRuntime ? shortcut.registered ? t("Active") : t("Unavailable") : t("Desktop only")}</span></div></div>
                <div className="settings-row"><div className="preference-copy"><strong>{t("Shortcut")}</strong><span>{shortcut.isDefault ? t("Using the default shortcut.") : t("Using your custom shortcut.")}</span></div><div className="preference-actions"><button disabled={!nativeRuntime || shortcutBusy || shortcutRecording || shortcutDraft === shortcut.accelerator} onClick={onShortcutSave}><Check size={14} />{t("Save")}</button><button disabled={!nativeRuntime || shortcutBusy || (shortcut.isDefault && !shortcut.issue)} onClick={onShortcutReset}><RefreshCw size={14} />{t("Reset")}</button></div></div>
              </div>
              {shortcutError || shortcut.issue ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(shortcutError || shortcut.issue?.message || "")}</span></div> : null}
            </>
          ) : null}

          {activeSection === "permissions" ? (
            <>
              <div className="settings-permission-summary">
                <span className={`permission-summary-icon ${accessibilityPermission.granted ? "granted" : ""}`}><ShieldCheck size={20} strokeWidth={1.8} /></span>
                <div><strong>{t("Native access, only when needed")}</strong><span>{t("마이크, 다른 앱 입력, 보조 키 단축키에 필요한 권한을 확인합니다.")}</span></div>
              </div>
              <DictationPermissions nativeRuntime={nativeRuntime} />
              <PermissionRuntimeDetails nativeRuntime={nativeRuntime && accessibilityPermission.supported} granted={accessibilityPermission.granted} />
              <div className="settings-group permission-group" role="group" aria-label={t("Accessibility")}>
                <h3 className="settings-group-title">{t("Accessibility")}</h3>
                <div className="settings-row">
                  <div className="preference-copy"><strong>{t("창 관리와 받아쓰기 입력")}</strong><span>{t("다른 앱의 창을 조절하거나 받아쓰기 결과를 입력할 때 사용합니다.")}</span></div>
                  <span className={`permission-status ${accessibilityPermission.granted ? "granted" : "required"}`}><span />{accessibilityPermission.granted ? t("Allowed") : accessibilityPermission.supported ? t("Needs access") : t("Not required")}</span>
                </div>
                <div className="settings-row permission-action-row">
                  <div className="preference-copy"><strong>{t("Manage permission")}</strong><span>{t(accessibilityPermission.message)} {t("일반 조합 단축키는 권한 없이 쓸 수 있지만, 보조 키 단독·두 번 누르기는 손쉬운 사용 권한이 필요합니다.")}</span></div>
                  <div className="preference-actions permission-actions">
                    {!accessibilityPermission.granted && accessibilityPermission.canRequest ? <button disabled={accessibilityPermissionBusy || accessibilityPermissionRequestPending} onClick={onAccessibilityPermissionRequest}><ShieldCheck size={14} />{accessibilityPermissionRequestPending ? t("허용 대기 중…") : t("Request Access")}</button> : null}
                    {accessibilityPermission.supported ? <button disabled={accessibilityPermissionBusy} onClick={onAccessibilitySettingsOpen}><ExternalLink size={14} />{t("System Settings")}</button> : null}
                    {accessibilityPermission.supported ? <button disabled={accessibilityPermissionBusy} onClick={onAccessibilityPermissionRefresh}><RefreshCw className={accessibilityPermissionBusy ? "spinning" : ""} size={14} />{t("Check Again")}</button> : null}
                  </div>
                </div>
              </div>
              {accessibilityPermissionError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(accessibilityPermissionError)}</span></div> : null}
            </>
          ) : null}

          {activeSection === "window-management" ? (
            <>
              <div className="window-intro"><div><strong>{t("Move and resize")}</strong><span>{t("Every layout is available in the command palette and can have its own alias and global hotkey.")}</span></div><span className="settings-count">{windowCommands.length} {t("layouts")}</span></div>
              {accessibilityPermission.supported && !accessibilityPermission.granted ? <button className="settings-inline-permission" onClick={() => { setSettingsQuery(""); setSection("permissions"); stopRecorders(); }}><ShieldCheck size={16} /><span><strong>{t("Accessibility access required")}</strong><small>{t("Review permission before using window layouts.")}</small></span><span>{t("Open Permissions")}</span></button> : null}
              <div className="settings-command-table window-command-table">
                <div className="settings-command-head"><span>{t("Layout")}</span><span>{t("Alias")}</span><span>{t("Hotkey")}</span></div>
                {windowCommands.map((command) => renderCommandRow(command))}
              </div>
              {commandHotkeyError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(commandHotkeyError)}</span></div> : null}
            </>
          ) : null}

          {activeSection === "commands" ? (
            <>
              <div className="settings-command-table">
                <div className="settings-command-head"><span>{t("Command")}</span><span>{t("Alias")}</span><span>{t("Hotkey")}</span></div>
                {otherCommands.map((command) => renderCommandRow(command))}
              </div>
              {commandHotkeyError ? <div className="preference-alert" role="alert"><TriangleAlert size={15} /><span>{t(commandHotkeyError)}</span></div> : null}
            </>
          ) : null}
        </div>
      </div>
    </section></InterfaceMotion>
  );
}
