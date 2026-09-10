import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";

import type { CommandAction, CommandItem, CommandProvider } from "@prism/command-core";

export const scriptCommandProviderId = "script-commands";
export const runScriptCommandActionId = "run-script-command";

export interface ScriptCommandSummary {
  id: string;
  title: string;
  description?: string;
  keywords: string[];
  arguments?: ScriptArgument[];
  argumentError?: string | null;
  timeoutSeconds?: number;
}

export interface ScriptArgument {
  type: "text" | "password" | "dropdown";
  placeholder: string;
  optional?: boolean;
  percentEncoded?: boolean;
  data?: { title: string; value: string }[];
}

export interface ScriptRunSnapshot {
  runId: string;
  scriptId?: string;
  state: "running" | "success" | "failure" | "cancelled" | "timedOut" | "interrupted";
  startedAtMs?: number;
  timeoutSeconds?: number;
  outputWithheld?: boolean;
  persistenceError?: string | null;
  result: ScriptCommandRunResult | null;
  error: string | null;
  stdout: string;
  stderr: string;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
}

export interface RefreshScriptCommandsRequest {
  directories: string[];
}

export interface RefreshScriptCommandsResult {
  commands: ScriptCommandSummary[];
  scannedDirectories: number;
  skippedEntries: number;
}

export interface RunScriptCommandRequest {
  scriptId: string;
}

export interface ScriptCommandRunResult {
  scriptId: string;
  succeeded: boolean;
  timedOut: boolean;
  cancelled?: boolean;
  exitCode: number | null;
  durationMs: number;
  stdout: string;
  stderr: string;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
}

export interface ScriptCommandActionTarget {
  actionId: typeof runScriptCommandActionId;
  scriptId: string;
}

function isTauriRuntime(): boolean {
  return Boolean(window.__TAURI_INTERNALS__);
}

function toCommandItem(command: ScriptCommandSummary): CommandItem {
  return {
    id: `script:${command.id}`,
    providerId: scriptCommandProviderId,
    title: command.title,
    subtitle: command.description ?? "Run a local script command",
    section: t("Script commands"),
    kind: "command",
    keywords: ["script", "local", ...command.keywords],
    icon: "terminal",
    accent: "mint",
    detail: {
      eyebrow: "Local script command",
      title: command.title,
      description:
        command.description ??
        "Runs directly from a configured local scripts directory. Prism never sends the script path to the renderer.",
      metadata: [
        { label: t("Runtime"), value: "Foreground" },
        { label: t("Timeout"), value: t("{0} seconds", { 0: command.timeoutSeconds ?? 10 }) },
        { label: t("Network"), value: "Not required by Prism" },
      ],
    },
    data: { scriptId: command.id },
    actions: [
      {
        id: runScriptCommandActionId,
        title: t("Run script"),
        shortcut: ["↵"],
        style: "accent",
      },
    ],
  };
}

export async function refreshScriptCommands(
  request: RefreshScriptCommandsRequest,
): Promise<RefreshScriptCommandsResult> {
  if (!isTauriRuntime()) {
    return { commands: [], scannedDirectories: 0, skippedEntries: 0 };
  }
  return invoke<RefreshScriptCommandsResult>("refresh_script_commands", {
    directories: request.directories,
  });
}

export async function listScriptCommands(): Promise<ScriptCommandSummary[]> {
  if (!isTauriRuntime()) return [];
  return invoke<ScriptCommandSummary[]>("list_script_commands");
}

export function getScriptCommandActionTarget(
  action: CommandAction,
  item: CommandItem,
): ScriptCommandActionTarget | undefined {
  if (action.id !== runScriptCommandActionId || item.providerId !== scriptCommandProviderId) {
    return undefined;
  }

  const scriptId = item.data?.scriptId;
  if (typeof scriptId !== "string" || !scriptId) return undefined;
  return { actionId: runScriptCommandActionId, scriptId };
}

export async function runScriptCommand(
  request: RunScriptCommandRequest,
): Promise<ScriptCommandRunResult> {
  if (!isTauriRuntime()) {
    throw new Error("Script commands require the Prism desktop runtime.");
  }
  return invoke<ScriptCommandRunResult>("run_script_command", {
    scriptId: request.scriptId,
  });
}

export async function runScriptCommandAction(
  action: CommandAction,
  item: CommandItem,
): Promise<ScriptCommandRunResult> {
  const target = getScriptCommandActionTarget(action, item);
  if (!target) throw new Error(`Unknown script command action: ${action.id}`);
  return runScriptCommand({ scriptId: target.scriptId });
}

export const nativeScriptCommandProvider: CommandProvider = {
  id: scriptCommandProviderId,
  get label() { return t("Script commands"); },
  async search(_query, signal) {
    if (!isTauriRuntime() || signal.aborted) return [];
    const commands = await listScriptCommands();
    if (signal.aborted) return [];
    return commands.map(toCommandItem);
  },
};

/** Resolve fresh metadata by opaque ID; this never executes the command. */
export async function getScriptCommandForItem(item: CommandItem): Promise<ScriptCommandSummary> {
  const id = item.providerId === scriptCommandProviderId ? item.data?.scriptId : undefined;
  if (typeof id !== "string") throw new Error("Invalid script command.");
  const script = (await listScriptCommands()).find((script) => script.id === id);
  if (!script) throw new Error("The script command is not present in the current registry.");
  return script;
}

export async function startScriptCommand(scriptId: string, args: string[]): Promise<ScriptRunSnapshot> {
  if (!isTauriRuntime()) throw new Error("Script commands require the Prism desktop runtime.");
  return invoke("start_script_command", { scriptId, args });
}

export async function getScriptCommandRun(runId: string): Promise<ScriptRunSnapshot> {
  return invoke("get_script_command_run", { runId });
}

export async function cancelScriptCommand(runId: string): Promise<ScriptRunSnapshot> {
  return invoke("cancel_script_command", { runId });
}

/** Read bounded durable and live snapshots without starting any execution. */
export async function listScriptCommandRuns(): Promise<ScriptRunSnapshot[]> {
  if (!isTauriRuntime()) return [];
  return invoke("list_script_command_runs");
}
