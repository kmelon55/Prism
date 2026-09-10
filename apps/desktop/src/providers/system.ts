import { t, localizeCommand } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import {
  createCatalogProvider,
  type CommandDefinition,
  type CommandManagement,
  type CommandProvider,
} from "@prism/command-core";

export type SystemPlatform = "macos" | "windows" | "linux" | "unsupported";

export const systemProviderId = "system";

export const systemCommandIds = {
  appearance: "system:settings:appearance",
  display: "system:settings:display",
  sound: "system:settings:sound",
  bluetooth: "system:settings:bluetooth",
  network: "system:settings:network",
  privacySecurity: "system:settings:privacy-security",
  notifications: "system:settings:notifications",
  keyboard: "system:settings:keyboard",
  mouse: "system:settings:mouse",
  trackpad: "system:settings:trackpad",
  powerBattery: "system:settings:power-battery",
  dateTime: "system:settings:date-time",
  softwareUpdate: "system:settings:software-update",
  lockScreen: "system:lock-screen",
} as const;

export const systemActionIds = {
  openSetting: "open-system-setting",
  lockScreen: "lock-screen",
} as const;

export interface SystemCommandResult {
  commandId: string;
  platform: Exclude<SystemPlatform, "unsupported">;
  applied: boolean;
  message: string;
}

interface SettingDescriptor {
  id: string;
  title: string;
  subtitle: string;
  keywords: readonly string[];
  icon: string;
  accent: string;
}

const manageableBuiltIn: CommandManagement = {
  source: "built-in",
  canConfigure: true,
  canDisable: true,
  canRemove: false,
};

const settingDescriptors: Readonly<Record<SystemPlatform, readonly SettingDescriptor[]>> = {
  macos: [
    setting(systemCommandIds.appearance, "Appearance", "Open macOS Appearance settings", ["theme", "dark", "light", "accent"], "sun-moon", "amber"),
    setting(systemCommandIds.display, "Displays", "Open macOS Displays settings", ["monitor", "resolution", "brightness", "night shift"], "monitor", "blue"),
    setting(systemCommandIds.sound, "Sound", "Open macOS Sound settings", ["audio", "volume", "speaker", "microphone"], "volume-2", "violet"),
    setting(systemCommandIds.bluetooth, "Bluetooth", "Open macOS Bluetooth settings", ["wireless", "devices", "pair", "airpods"], "bluetooth", "blue"),
    setting(systemCommandIds.network, "Network", "Open macOS Network settings", ["wifi", "wi-fi", "ethernet", "vpn", "internet"], "network", "mint"),
    setting(systemCommandIds.privacySecurity, "Privacy & Security", "Open macOS Privacy & Security settings", ["permissions", "security", "location", "camera", "microphone"], "shield-check", "rose"),
    setting(systemCommandIds.notifications, "Notifications", "Open macOS Notifications settings", ["alerts", "focus", "banners", "sounds"], "bell", "violet"),
    setting(systemCommandIds.keyboard, "Keyboard", "Open macOS Keyboard settings", ["input", "text", "shortcuts", "language"], "keyboard", "mint"),
    setting(systemCommandIds.mouse, "Mouse", "Open macOS Mouse settings", ["pointer", "click", "scroll", "tracking"], "mouse", "blue"),
    setting(systemCommandIds.trackpad, "Trackpad", "Open macOS Trackpad settings", ["gesture", "click", "scroll", "tracking"], "panels-top-left", "blue"),
    setting(systemCommandIds.powerBattery, "Battery", "Open macOS Battery settings", ["power", "energy", "charging", "low power"], "battery-charging", "mint"),
    setting(systemCommandIds.dateTime, "Date & Time", "Open macOS Date & Time settings", ["clock", "timezone", "calendar", "automatic"], "clock-3", "amber"),
    setting(systemCommandIds.softwareUpdate, "Software Update", "Open macOS Software Update settings", ["update", "upgrade", "version", "macos"], "refresh", "mint"),
  ],
  windows: [
    setting(systemCommandIds.appearance, "Personalization", "Open Windows Personalization settings", ["appearance", "theme", "background", "colors"], "sun-moon", "amber"),
    setting(systemCommandIds.display, "Display", "Open Windows Display settings", ["monitor", "resolution", "brightness", "scale"], "monitor", "blue"),
    setting(systemCommandIds.sound, "Sound", "Open Windows Sound settings", ["audio", "volume", "speaker", "microphone"], "volume-2", "violet"),
    setting(systemCommandIds.bluetooth, "Bluetooth", "Open Windows Bluetooth settings", ["wireless", "devices", "pair", "headphones"], "bluetooth", "blue"),
    setting(systemCommandIds.network, "Network & internet", "Open Windows Network settings", ["wifi", "wi-fi", "ethernet", "vpn", "internet"], "network", "mint"),
    setting(systemCommandIds.privacySecurity, "Privacy", "Open Windows Privacy settings", ["permissions", "security", "location", "camera", "microphone"], "shield-check", "rose"),
    setting(systemCommandIds.notifications, "Notifications", "Open Windows Notifications settings", ["alerts", "focus", "banners", "sounds"], "bell", "violet"),
    setting(systemCommandIds.keyboard, "Typing", "Open Windows Typing settings", ["keyboard", "input", "text", "language"], "keyboard", "mint"),
    setting(systemCommandIds.mouse, "Mouse & touchpad", "Open Windows Mouse settings", ["pointer", "click", "scroll", "touchpad"], "mouse", "blue"),
    setting(systemCommandIds.powerBattery, "Power & battery", "Open Windows Power settings", ["battery", "energy", "charging", "sleep"], "battery-charging", "mint"),
    setting(systemCommandIds.dateTime, "Date & time", "Open Windows Date & time settings", ["clock", "timezone", "calendar", "automatic"], "clock-3", "amber"),
    setting(systemCommandIds.softwareUpdate, "Windows Update", "Open Windows Update settings", ["update", "upgrade", "version", "windows"], "refresh", "mint"),
  ],
  linux: [
    setting(systemCommandIds.appearance, "Appearance", "Open desktop appearance settings", ["theme", "dark", "light", "background"], "sun-moon", "amber"),
    setting(systemCommandIds.display, "Displays", "Open desktop display settings", ["monitor", "resolution", "brightness", "scale"], "monitor", "blue"),
    setting(systemCommandIds.sound, "Sound", "Open desktop sound settings", ["audio", "volume", "speaker", "microphone"], "volume-2", "violet"),
    setting(systemCommandIds.bluetooth, "Bluetooth", "Open desktop Bluetooth settings", ["wireless", "devices", "pair", "headphones"], "bluetooth", "blue"),
    setting(systemCommandIds.network, "Network", "Open desktop network settings", ["wifi", "wi-fi", "ethernet", "vpn", "internet"], "network", "mint"),
    setting(systemCommandIds.privacySecurity, "Privacy", "Open desktop privacy settings", ["permissions", "security", "location", "camera", "microphone"], "shield-check", "rose"),
    setting(systemCommandIds.notifications, "Notifications", "Open desktop notification settings", ["alerts", "banners", "sounds", "do not disturb"], "bell", "violet"),
    setting(systemCommandIds.keyboard, "Keyboard", "Open desktop keyboard settings", ["input", "text", "shortcuts", "language"], "keyboard", "mint"),
    setting(systemCommandIds.mouse, "Mouse & touchpad", "Open desktop pointer settings", ["pointer", "click", "scroll", "touchpad"], "mouse", "blue"),
    setting(systemCommandIds.powerBattery, "Power", "Open desktop power settings", ["battery", "energy", "charging", "suspend"], "battery-charging", "mint"),
    setting(systemCommandIds.dateTime, "Date & time", "Open desktop Date & time settings", ["clock", "timezone", "calendar", "automatic"], "clock-3", "amber"),
    setting(systemCommandIds.softwareUpdate, "Software Update", "Open desktop software settings", ["update", "upgrade", "packages", "linux"], "refresh", "mint"),
  ],
  unsupported: [],
};

function setting(
  id: string,
  title: string,
  subtitle: string,
  keywords: readonly string[],
  icon: string,
  accent: string,
): SettingDescriptor {
  return { id, title, subtitle, keywords, icon, accent };
}

function platformLabel(platform: Exclude<SystemPlatform, "unsupported">): string {
  if (platform === "macos") return "macOS";
  if (platform === "windows") return "Windows";
  return t("Linux desktop");
}

function settingDefinition(
  platform: Exclude<SystemPlatform, "unsupported">,
  descriptor: SettingDescriptor,
): CommandDefinition {
  return {
    id: descriptor.id,
    title: descriptor.title,
    subtitle: descriptor.subtitle,
    section: t("System Settings"),
    kind: "setting",
    keywords: ["system", "settings", "preferences", ...descriptor.keywords],
    icon: descriptor.icon,
    iconTarget: descriptor.id,
    accent: descriptor.accent,
    detail: {
      eyebrow: `${platformLabel(platform)} setting`,
      title: descriptor.title,
      description: t("Open the matching {0} settings page without exposing an executable or URI to the renderer.", {"0": platformLabel(platform)}),
      metadata: [
        { label: t("Platform"), value: platformLabel(platform) },
        { label: t("Handled by"), value: t("Prism native allowlist") },
      ],
    },
    data: { systemCommandId: descriptor.id },
    actions: [
      {
        id: systemActionIds.openSetting,
        title: t("Open {0}", {"0": descriptor.title}),
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: { ...manageableBuiltIn },
  };
}

function lockScreenDefinition(
  platform: Exclude<SystemPlatform, "unsupported">,
): CommandDefinition {
  return {
    id: systemCommandIds.lockScreen,
    title: t("Lock Screen"),
    subtitle: t("Lock this {0} session", {"0": platformLabel(platform)}),
    section: t("System Actions"),
    kind: "command",
    keywords: ["system", "lock", "screen", "session", "security"],
    icon: "lock-keyhole",
    iconTarget: systemCommandIds.lockScreen,
    accent: "rose",
    rankingBoost: 0.2,
    detail: {
      eyebrow: t("Safe system action"),
      title: t("Lock Screen"),
      description: t("Locks the current session. Prism does not expose restart, shutdown, or sleep actions."),
      metadata: [
        { label: t("Platform"), value: platformLabel(platform) },
        { label: t("Effect"), value: t("Locks the current session") },
      ],
    },
    data: { systemCommandId: systemCommandIds.lockScreen },
    actions: [
      {
        id: systemActionIds.lockScreen,
        title: t("Lock Screen"),
        shortcut: ["↵"],
        style: "accent",
      },
    ],
    management: { ...manageableBuiltIn },
  };
}

export function systemCommandDefinitions(platform: SystemPlatform): readonly CommandDefinition[] {
  if (platform === "unsupported") return [];
  return [
    ...settingDescriptors[platform].map((descriptor) => settingDefinition(platform, descriptor)),
    lockScreenDefinition(platform),
  ];
}

export function createSystemProvider(platform: SystemPlatform): CommandProvider {
  const provider = createCatalogProvider({id:systemProviderId,label:t("System"),commands:systemCommandDefinitions(platform)});
  return {...provider, async search(query,signal) {return (await provider.search(query,signal)).map(localizeCommand);}};
}

function browserPlatform(): SystemPlatform {
  if (typeof navigator === "undefined") return "unsupported";
  const platform = `${navigator.platform} ${navigator.userAgent}`.toLowerCase();
  if (platform.includes("mac")) return "macos";
  if (platform.includes("win")) return "windows";
  if (platform.includes("linux")) return "linux";
  return "unsupported";
}

let platformRequest: Promise<SystemPlatform> | undefined;

export function getSystemPlatform(): Promise<SystemPlatform> {
  if (typeof window === "undefined" || !window.__TAURI_INTERNALS__) {
    return Promise.resolve(browserPlatform());
  }
  platformRequest ??= invoke<SystemPlatform>("system_platform").catch(() => "unsupported");
  return platformRequest;
}

export const systemProvider: CommandProvider = {
  id: systemProviderId,
  get label() { return t("System"); },
  async search(query, signal) {
    const platform = await getSystemPlatform();
    if (signal.aborted || platform === "unsupported") return [];
    return createSystemProvider(platform).search(query, signal);
  },
};

export function runSystemCommand(
  actionId: string,
  commandId: string,
): Promise<SystemCommandResult> {
  if (actionId === systemActionIds.openSetting) {
    return invoke<SystemCommandResult>("open_system_setting", { commandId });
  }
  if (actionId === systemActionIds.lockScreen && commandId === systemCommandIds.lockScreen) {
    return invoke<SystemCommandResult>("lock_screen");
  }
  return Promise.reject(new Error(t("Unknown system action: {0}", {"0": actionId})));
}
