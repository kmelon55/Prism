import { getDesktopCapabilities } from "./system";
import { t, localizeCommand, bilingual } from "../i18n";
import {
  createCatalogProvider,
  type CommandDefinition,
  type CommandManagement,
  type CommandProvider,
} from "@prism/command-core";

export const prismCommandIds = {
  library: "prism:library",
  links: "prism:links",
  snippets: "prism:snippets",
  files: "prism:files",
  emoji: "prism:emoji",
  aiChat: "prism:ai-chat",
  dictation: "prism:dictation",
  dictationPrompt: "prism:dictation-prompt",
  preferences: "prism:preferences",
  theme: "prism:cycle-theme",
  hide: "prism:hide",
  quit: "prism:quit",
  refreshApplications: "prism:refresh-application-index",
  clearIconCache: "prism:clear-application-icon-cache",
  clearClipboardHistory: "clipboard:clear-history",
  clipboardHistory: "clipboard:open-history",
  windowLeft: "window:left-half",
  windowRight: "window:right-half",
  windowTop: "window:top-half",
  windowBottom: "window:bottom-half",
  windowTopLeft: "window:top-left-quarter",
  windowTopRight: "window:top-right-quarter",
  windowBottomLeft: "window:bottom-left-quarter",
  windowBottomRight: "window:bottom-right-quarter",
  windowTopLeftSixth: "window:top-left-sixth",
  windowTopCenterSixth: "window:top-center-sixth",
  windowTopRightSixth: "window:top-right-sixth",
  windowBottomLeftSixth: "window:bottom-left-sixth",
  windowBottomCenterSixth: "window:bottom-center-sixth",
  windowBottomRightSixth: "window:bottom-right-sixth",
  windowFirstThird: "window:first-third",
  windowCenterThird: "window:center-third",
  windowLastThird: "window:last-third",
  windowLeftTwoThirds: "window:left-two-thirds",
  windowCenterTwoThirds: "window:center-two-thirds",
  windowRightTwoThirds: "window:right-two-thirds",
  windowMaximize: "window:maximize",
  windowAlmostMaximize: "window:almost-maximize",
  windowCenter: "window:center",
  windowRestorePrevious: "window:restore-previous-layout",
} as const;

export const prismActionIds = {
  openLibrary: "open-library",
  openLinks: "open-links",
  openSnippets: "open-snippets",
  openFiles: "open-files",
  openEmoji: "open-emoji",
  openAiChat: "open-ai-chat",
  toggleDictation: "toggle-dictation",
  toggleDictationPrompt: "toggle-dictation-prompt",
  openPreferences: "open-settings",
  cycleTheme: "cycle-theme",
  hide: "hide-prism",
  quit: "quit-prism",
  refreshApplications: "refresh-application-index",
  clearIconCache: "clear-application-icon-cache",
  clearClipboardHistory: "clear-clipboard-history",
  openClipboardHistory: "open-clipboard-history",
  windowLeft: "manage-window-left-half",
  windowRight: "manage-window-right-half",
  windowTop: "manage-window-top-half",
  windowBottom: "manage-window-bottom-half",
  windowTopLeft: "manage-window-top-left-quarter",
  windowTopRight: "manage-window-top-right-quarter",
  windowBottomLeft: "manage-window-bottom-left-quarter",
  windowBottomRight: "manage-window-bottom-right-quarter",
  windowTopLeftSixth: "manage-window-top-left-sixth",
  windowTopCenterSixth: "manage-window-top-center-sixth",
  windowTopRightSixth: "manage-window-top-right-sixth",
  windowBottomLeftSixth: "manage-window-bottom-left-sixth",
  windowBottomCenterSixth: "manage-window-bottom-center-sixth",
  windowBottomRightSixth: "manage-window-bottom-right-sixth",
  windowFirstThird: "manage-window-first-third",
  windowCenterThird: "manage-window-center-third",
  windowLastThird: "manage-window-last-third",
  windowLeftTwoThirds: "manage-window-left-two-thirds",
  windowCenterTwoThirds: "manage-window-center-two-thirds",
  windowRightTwoThirds: "manage-window-right-two-thirds",
  windowMaximize: "manage-window-maximize",
  windowAlmostMaximize: "manage-window-almost-maximize",
  windowCenter: "manage-window-center",
  windowRestorePrevious: "manage-window-restore-previous-layout",
} as const;

export const prismProviderId = "prism";

const requiredBuiltInManagement: CommandManagement = {
  source: "built-in",
  canConfigure: true,
  canDisable: false,
  canRemove: false,
};

const manageableBuiltInManagement: CommandManagement = {
  ...requiredBuiltInManagement,
  canDisable: true,
};

const commonDefinitions: readonly CommandDefinition[] = [
  { id: prismCommandIds.dictation, get title() { return t("음성 받아쓰기"); }, get subtitle() { return t("녹음 시작 · 다시 실행하면 전사 후 입력"); }, get section() { return t("Productivity"); }, kind: "command", keywords: ["dictation", "whisp", "voice", "speech", "transcribe", "음성", "받아쓰기", "녹음", "전사"], icon: "mic", actions: [{ id: prismActionIds.toggleDictation, get title() { return t("받아쓰기 시작 / 종료"); } }], management: manageableBuiltInManagement },
  { id: prismCommandIds.dictationPrompt, get title() { return t("Structure prompt"); }, get subtitle() { return t("Speak to create a clear prompt · Run again to insert"); }, get section() { return t("Productivity"); }, kind: "command", keywords: ["dictation", "prompt", "프롬프트", "정리", "음성"], icon: "mic", actions: [{ id: prismActionIds.toggleDictationPrompt, get title() { return t("Structure prompt"); } }], management: manageableBuiltInManagement },
  {id:prismCommandIds.emoji,get title() { return t("이모지"); },get subtitle() { return t("이모지를 찾아 복사하거나 붙여넣으세요"); },get section() { return t("Productivity"); },kind:"command",keywords:["emoji","emojis","이모지","이모티콘","표정","symbols"],icon:"smile",actions:[{id:prismActionIds.openEmoji,get title() { return t("열기"); }}],management:manageableBuiltInManagement},
  {id:prismCommandIds.links,get title() { return t("Quicklinks"); },get subtitle() { return t("저장한 웹사이트와 파일 바로가기"); },get section() { return t("Productivity"); },kind:"command",keywords:["links","링크","바로가기"],icon:"globe",actions:[{id:prismActionIds.openLinks,get title() { return t("열기"); }}],management:manageableBuiltInManagement},
  {id:prismCommandIds.snippets,get title() { return t("Snippets"); },get subtitle() { return t("자주 쓰는 문구"); },get section() { return t("Productivity"); },kind:"command",keywords:["snippet","스니펫","문구"],icon:"clipboard",actions:[{id:prismActionIds.openSnippets,get title() { return t("열기"); }}],management:manageableBuiltInManagement},
  {id:prismCommandIds.files,get title() { return t("File Search"); },get subtitle() { return t("파일 이름은 팔레트에서 바로 검색하세요"); },get section() { return t("Productivity"); },kind:"command",keywords:["files","파일","검색","folders"],icon:"folder-open",actions:[{id:prismActionIds.openFiles,get title() { return t("열기"); }}],management:manageableBuiltInManagement},
  {id:prismCommandIds.library,get title() { return t("보관함"); },get subtitle() { return t("링크, 스니펫, 파일 검색, 즐겨찾기"); },get section() { return t("Productivity"); },kind:"command",keywords:["library","files","snippets","favorites","quicklinks","파일","검색","링크","스니펫","즐겨찾기"],icon:"folder-open",actions:[{id:prismActionIds.openLibrary,get title() { return t("보관함 열기"); }}],management:manageableBuiltInManagement},
  {
    id: prismCommandIds.aiChat,
    get title() { return t("AI Chat"); },
    get subtitle() { return t("내 API 키로 대화, 번역, 요약"); },
    get section() { return t("Productivity"); },
    kind: "command",
    keywords: ["ai", "chat", "ask", "openai", "openrouter", "byok", "대화", "질문", "번역", "요약", "인공지능"],
    icon: "sparkles",
    accent: "violet",
    actions: [{ id: prismActionIds.openAiChat, get title() { return t("Open AI Chat"); }, shortcut: ["↵"], style: "accent" }],
    management: manageableBuiltInManagement,
  },
  {
    id: prismCommandIds.preferences,
    get title() { return t("Settings"); },
    get subtitle() { return t("Appearance, clipboard, aliases, and shortcuts"); },
    section: "Prism",
    kind: "setting",
    keywords: ["settings", "configuration", "motion", "icons", "clipboard", "shortcut", "alias"],
    icon: "prism",
    accent: "blue",
    detail: {
      eyebrow: "Built-in command",
      get title() { return t("Make the palette feel native to you"); },
      get description() { return t("Open the dedicated settings window for appearance, privacy, aliases, and command shortcuts."); },
      metadata: [
        { get label() { return t("Shortcut"); }, value: "Cmd/Ctrl ," },
        { get label() { return t("Storage"); }, value: "Local device" },
      ],
    },
    actions: [
      {
        id: prismActionIds.openPreferences,
        get title() { return t("Open Settings"); },
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: requiredBuiltInManagement,
  },
  {
    id: prismCommandIds.clipboardHistory,
    get title() { return t("Clipboard History"); },
    get subtitle() { return t("Browse and reuse text copied on this device"); },
    get section() { return t("Productivity"); },
    kind: "command",
    keywords: ["clipboard", "history", "copy", "paste", "recent"],
    icon: "clipboard",
    accent: "violet",
    actions: [
      {
        id: prismActionIds.openClipboardHistory,
        get title() { return t("Open Clipboard History"); },
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: manageableBuiltInManagement,
  },
  {
    id: prismCommandIds.theme,
    get title() { return t("Cycle Appearance"); },
    get subtitle() { return t("System → dark → light"); },
    section: "Prism",
    kind: "setting",
    keywords: ["theme", "dark", "light", "system", "appearance"],
    icon: "sun-moon",
    accent: "amber",
    detail: {
      eyebrow: "Built-in command",
      get title() { return t("Cycle Prism appearance"); },
      get description() { return t("Moves between the system, dark, and light appearance preferences."); },
      metadata: [
        { get label() { return t("Modes"); }, value: "System · Dark · Light" },
        { get label() { return t("Shortcut"); }, value: "Cmd/Ctrl Shift T" },
      ],
    },
    actions: [
      {
        id: prismActionIds.cycleTheme,
        get title() { return t("Cycle appearance"); },
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: manageableBuiltInManagement,
  },
  {
    id: prismCommandIds.hide,
    get title() { return t("Hide Prism"); },
    get subtitle() { return t("Keep Prism ready in the background"); },
    section: "Prism",
    kind: "command",
    keywords: ["close", "dismiss", "background", "window"],
    icon: "hide",
    accent: "violet",
    detail: {
      eyebrow: "Built-in command",
      get title() { return t("Out of sight, still ready"); },
      get description() { return t("Hides the palette without stopping Prism. Use the global shortcut to bring it back."); },
      metadata: [
        { label: "macOS", value: "Cmd Shift Space" },
        { label: "Windows / Linux", value: "Ctrl Shift Space" },
      ],
    },
    actions: [
      {
        id: prismActionIds.hide,
        get title() { return t("Hide Prism"); },
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: manageableBuiltInManagement,
  },
  {
    id: prismCommandIds.quit,
    get title() { return t("Quit Prism"); },
    get subtitle() { return t("Stop Prism and its background shortcuts"); },
    section: "Prism",
    kind: "command",
    keywords: ["quit", "exit", "stop", "prism", "종료", "프리즘"],
    icon: "power",
    actions: [{ id: prismActionIds.quit, get title() { return t("Quit Prism"); } }],
    management: requiredBuiltInManagement,
  },
];

const applicationMaintenanceDefinitions: readonly CommandDefinition[] = [
  {
    id: prismCommandIds.refreshApplications,
    get title() { return t("Refresh application index"); },
    get subtitle() { return t("Find recently installed or removed applications"); },
    section: "Prism maintenance",
    kind: "command",
    keywords: ["apps", "catalog", "index", "scan", "reload"],
    icon: "refresh",
    accent: "mint",
    detail: {
      eyebrow: "Built-in maintenance",
      get title() { return t("Refresh installed applications"); },
      get description() { return t("Asks the native application catalog to rescan the platform's known application locations."); },
      metadata: [
        { get label() { return t("Runtime"); }, value: "Desktop only" },
        { get label() { return t("Network"); }, value: "Not required" },
      ],
    },
    actions: [
      {
        id: prismActionIds.refreshApplications,
        get title() { return t("Refresh application index"); },
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: manageableBuiltInManagement,
  },
  {
    id: prismCommandIds.clearIconCache,
    get title() { return t("Clear application icon cache"); },
    get subtitle() { return t("Discard locally saved application artwork"); },
    section: "Prism maintenance",
    kind: "command",
    keywords: ["apps", "icons", "cache", "artwork", "reset"],
    icon: "trash",
    accent: "rose",
    detail: {
      eyebrow: "Built-in maintenance",
      get title() { return t("Clear cached application icons"); },
      get description() { return t("Removes locally cached icon artwork. Visible application icons are loaded again when needed."); },
      metadata: [
        { get label() { return t("Runtime"); }, value: "Desktop only" },
        { label: "Scope", value: "Generated icon cache" },
      ],
    },
    actions: [
      {
        id: prismActionIds.clearIconCache,
        get title() { return t("Clear application icon cache"); },
        shortcut: ["↵"],
        style: "danger",
      },
    ],
    management: manageableBuiltInManagement,
  },
  {
    id: prismCommandIds.clearClipboardHistory,
    get title() { return t("Clear clipboard history"); },
    get subtitle() { return t("Remove every locally stored clipboard entry"); },
    get section() { return t("Clipboard history"); },
    kind: "command",
    keywords: ["clipboard", "privacy", "clear", "delete"],
    icon: "clipboard-x",
    accent: "rose",
    detail: {
      eyebrow: "Privacy command",
      get title() { return t("Clear local clipboard history"); },
      get description() { return t("Permanently removes clipboard entries stored by Prism on this device."); },
      metadata: [
        { get label() { return t("Network"); }, value: "Never used" },
        { label: "Scope", value: "This device" },
      ],
    },
    actions: [
      {
        id: prismActionIds.clearClipboardHistory,
        get title() { return t("Clear clipboard history"); },
        shortcut: ["↵"],
        style: "danger",
      },
    ],
    management: manageableBuiltInManagement,
  },
];

const windowLayouts = [
  { id: prismCommandIds.windowLeft, action: prismActionIds.windowLeft, get title() { return t("Left Half"); }, keywords: ["left", "half"], icon: "panel-left" },
  { id: prismCommandIds.windowRight, action: prismActionIds.windowRight, get title() { return t("Right Half"); }, keywords: ["right", "half"], icon: "panel-right" },
  { id: prismCommandIds.windowTop, action: prismActionIds.windowTop, get title() { return t("Top Half"); }, keywords: ["top", "half"], icon: "scan" },
  { id: prismCommandIds.windowBottom, action: prismActionIds.windowBottom, get title() { return t("Bottom Half"); }, keywords: ["bottom", "half"], icon: "scan" },
  { id: prismCommandIds.windowTopLeft, action: prismActionIds.windowTopLeft, get title() { return t("Top Left Quarter"); }, keywords: ["top", "left", "quarter"], icon: "scan" },
  { id: prismCommandIds.windowTopRight, action: prismActionIds.windowTopRight, get title() { return t("Top Right Quarter"); }, keywords: ["top", "right", "quarter"], icon: "scan" },
  { id: prismCommandIds.windowBottomLeft, action: prismActionIds.windowBottomLeft, get title() { return t("Bottom Left Quarter"); }, keywords: ["bottom", "left", "quarter"], icon: "scan" },
  { id: prismCommandIds.windowBottomRight, action: prismActionIds.windowBottomRight, get title() { return t("Bottom Right Quarter"); }, keywords: ["bottom", "right", "quarter"], icon: "scan" },
  { id: prismCommandIds.windowTopLeftSixth, action: prismActionIds.windowTopLeftSixth, get title() { return t("Top Left Sixth"); }, keywords: ["top", "left", "sixth"], icon: "scan" },
  { id: prismCommandIds.windowTopCenterSixth, action: prismActionIds.windowTopCenterSixth, get title() { return t("Top Center Sixth"); }, keywords: ["top", "center", "sixth"], icon: "scan" },
  { id: prismCommandIds.windowTopRightSixth, action: prismActionIds.windowTopRightSixth, get title() { return t("Top Right Sixth"); }, keywords: ["top", "right", "sixth"], icon: "scan" },
  { id: prismCommandIds.windowBottomLeftSixth, action: prismActionIds.windowBottomLeftSixth, get title() { return t("Bottom Left Sixth"); }, keywords: ["bottom", "left", "sixth"], icon: "scan" },
  { id: prismCommandIds.windowBottomCenterSixth, action: prismActionIds.windowBottomCenterSixth, get title() { return t("Bottom Center Sixth"); }, keywords: ["bottom", "center", "sixth"], icon: "scan" },
  { id: prismCommandIds.windowBottomRightSixth, action: prismActionIds.windowBottomRightSixth, get title() { return t("Bottom Right Sixth"); }, keywords: ["bottom", "right", "sixth"], icon: "scan" },
  { id: prismCommandIds.windowFirstThird, action: prismActionIds.windowFirstThird, get title() { return t("First Third"); }, keywords: ["left", "first", "third"], icon: "panel-left" },
  { id: prismCommandIds.windowCenterThird, action: prismActionIds.windowCenterThird, get title() { return t("Center Third"); }, keywords: ["center", "middle", "third"], icon: "scan" },
  { id: prismCommandIds.windowLastThird, action: prismActionIds.windowLastThird, get title() { return t("Last Third"); }, keywords: ["right", "last", "third"], icon: "panel-right" },
  { id: prismCommandIds.windowLeftTwoThirds, action: prismActionIds.windowLeftTwoThirds, get title() { return t("Left Two Thirds"); }, keywords: ["left", "two", "thirds"], icon: "panel-left" },
  { id: prismCommandIds.windowCenterTwoThirds, action: prismActionIds.windowCenterTwoThirds, get title() { return t("Center Two Thirds"); }, keywords: ["center", "two", "thirds"], icon: "scan" },
  { id: prismCommandIds.windowRightTwoThirds, action: prismActionIds.windowRightTwoThirds, get title() { return t("Right Two Thirds"); }, keywords: ["right", "two", "thirds"], icon: "panel-right" },
  { id: prismCommandIds.windowMaximize, action: prismActionIds.windowMaximize, get title() { return t("Maximize"); }, keywords: ["maximize", "fill", "screen"], icon: "maximize" },
  { id: prismCommandIds.windowAlmostMaximize, action: prismActionIds.windowAlmostMaximize, get title() { return t("Almost Maximize"); }, keywords: ["almost", "maximize", "margin"], icon: "maximize" },
  { id: prismCommandIds.windowCenter, action: prismActionIds.windowCenter, get title() { return t("Center"); }, keywords: ["center", "position"], icon: "scan" },
  { id: "window:maximize-width", action: "manage-window-maximize-width", get title() { return t("Maximize Width"); }, keywords: ["maximize", "width"], icon: "scan" },
  { id: "window:maximize-height", action: "manage-window-maximize-height", get title() { return t("Maximize Height"); }, keywords: ["maximize", "height"], icon: "scan" },
  { id: "window:reasonable-size", action: "manage-window-reasonable-size", get title() { return t("Reasonable Size"); }, keywords: ["reasonable", "size"], icon: "scan" },
  { id: "window:first-fourth", action: "manage-window-first-fourth", get title() { return t("First Fourth"); }, keywords: ["first", "fourth"], icon: "scan" },
  { id: "window:second-fourth", action: "manage-window-second-fourth", get title() { return t("Second Fourth"); }, keywords: ["second", "fourth"], icon: "scan" },
  { id: "window:third-fourth", action: "manage-window-third-fourth", get title() { return t("Third Fourth"); }, keywords: ["third", "fourth"], icon: "scan" },
  { id: "window:last-fourth", action: "manage-window-last-fourth", get title() { return t("Last Fourth"); }, keywords: ["last", "fourth"], icon: "scan" },
  { id: "window:move-left", action: "manage-window-move-left", get title() { return t("Move Left"); }, keywords: ["move", "left"], icon: "scan" },
  { id: "window:move-right", action: "manage-window-move-right", get title() { return t("Move Right"); }, keywords: ["move", "right"], icon: "scan" },
  { id: "window:move-up", action: "manage-window-move-up", get title() { return t("Move Up"); }, keywords: ["move", "up"], icon: "scan" },
  { id: "window:move-down", action: "manage-window-move-down", get title() { return t("Move Down"); }, keywords: ["move", "down"], icon: "scan" },
  { id: "window:next-display", action: "manage-window-next-display", get title() { return t("Next Display"); }, keywords: ["next", "display"], icon: "scan" },
  { id: "window:previous-display", action: "manage-window-previous-display", get title() { return t("Previous Display"); }, keywords: ["previous", "display"], icon: "scan" },

  { id: prismCommandIds.windowRestorePrevious, action: prismActionIds.windowRestorePrevious, get title() { return t("Restore Previous Layout"); }, keywords: ["restore", "previous", "undo"], icon: "history" },
] as const;

const windowManagementDefinitions: readonly CommandDefinition[] = windowLayouts.map((layout) => ({
  id: layout.id,
  title: layout.title,
  subtitle: layout.id === prismCommandIds.windowRestorePrevious
    ? "Restore the frontmost window to its previous Prism layout"
    : t("Move the frontmost window to {0}", {"0": layout.title.toLowerCase()}),
  section: t("Window management"),
  kind: "command",
  keywords: ["window", "move", "resize", "layout", ...layout.keywords, ...bilingual(layout.title)],
  icon: `window-layout:${layout.id.slice("window:".length)}`,
  accent: "blue",
  actions: [{ id: layout.action, title: t("Apply {0}", {"0": layout.title}), shortcut: ["↵"], style: "accent" }],
  management: manageableBuiltInManagement,
}));

export const prismCommandDefinitions = [
  ...commonDefinitions,
  ...applicationMaintenanceDefinitions,
  ...windowManagementDefinitions,
] as const satisfies readonly CommandDefinition[];

export function createPrismProvider(): CommandProvider {
  const commands = [...commonDefinitions, ...windowManagementDefinitions];
  const provider = createCatalogProvider({
    id: prismProviderId,
    label: "Prism",
    commands,
  });
  const topLevelIds = new Set(commonDefinitions.map((command) => command.id));

  return {
    ...provider,
    async search(query, signal) {
      const capabilities = await getDesktopCapabilities();
      const items = (await provider.search(query, signal)).filter(item => !item.id.startsWith("window:") || capabilities?.windowManagement !== false).map(localizeCommand);
      return query.trim() ? items : items.filter((item) => topLevelIds.has(item.id));
    },
  };
}

export const prismProvider = createPrismProvider();
export const nativePrismProvider = createPrismProvider();
