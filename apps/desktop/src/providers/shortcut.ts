import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";

export type GlobalShortcutIssueCode =
  | "invalidPersistedShortcut"
  | "invalidShortcut"
  | "persistenceFailed"
  | "registrationConflict"
  | "registrationFailed"
  | "stateUnavailable";

export interface GlobalShortcutIssue {
  code: GlobalShortcutIssueCode;
  message: string;
}

export interface GlobalShortcutSetting {
  accelerator: string;
  defaultAccelerator: string;
  isDefault: boolean;
  registered: boolean;
  issue: GlobalShortcutIssue | null;
}

export interface GlobalShortcutCommandFailure extends GlobalShortcutIssue {
  attemptedAccelerator: string | null;
  active: GlobalShortcutSetting;
}

export class GlobalShortcutCommandError extends Error {
  readonly code: GlobalShortcutIssueCode;
  readonly attemptedAccelerator: string | null;
  readonly active: GlobalShortcutSetting;

  constructor(failure: GlobalShortcutCommandFailure) {
    super(failure.message);
    this.name = "GlobalShortcutCommandError";
    this.code = failure.code;
    this.attemptedAccelerator = failure.attemptedAccelerator;
    this.active = failure.active;
  }
}

function isCommandFailure(value: unknown): value is GlobalShortcutCommandFailure {
  if (!value || typeof value !== "object") return false;
  const failure = value as Partial<GlobalShortcutCommandFailure>;
  return (
    typeof failure.code === "string" &&
    typeof failure.message === "string" &&
    typeof failure.active === "object" &&
    failure.active !== null
  );
}

async function invokeShortcutCommand(
  command: string,
  args?: Record<string, unknown>,
): Promise<GlobalShortcutSetting> {
  try {
    return await invoke<GlobalShortcutSetting>(command, args);
  } catch (error) {
    if (isCommandFailure(error)) throw new GlobalShortcutCommandError(error);
    throw error;
  }
}

export function getGlobalShortcut(): Promise<GlobalShortcutSetting> {
  return invokeShortcutCommand("get_global_shortcut");
}

export function setGlobalShortcut(accelerator: string): Promise<GlobalShortcutSetting> {
  return invokeShortcutCommand("set_global_shortcut", { accelerator }).then(async (setting) => {
    await emit("prism:global-shortcut-changed", setting).catch((error) => {
      console.error("Prism could not broadcast the global shortcut change", error);
    });
    return setting;
  });
}

export function resetGlobalShortcut(): Promise<GlobalShortcutSetting> {
  return invokeShortcutCommand("reset_global_shortcut").then(async (setting) => {
    await emit("prism:global-shortcut-changed", setting).catch((error) => {
      console.error("Prism could not broadcast the global shortcut reset", error);
    });
    return setting;
  });
}

export function onGlobalShortcutChanged(
  callback: (setting: GlobalShortcutSetting) => void,
): Promise<() => void> {
  return listen<GlobalShortcutSetting>("prism:global-shortcut-changed", (event) => {
    callback(event.payload);
  });
}
