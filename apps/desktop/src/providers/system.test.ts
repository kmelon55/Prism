import { beforeEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { rankCommands } from "@prism/command-core";
import { createSystemProvider, runSystemCommand, systemActionIds, systemCommandDefinitions, systemCommandIds } from "./system";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
beforeEach(() => { vi.mocked(invoke).mockReset(); localStorage.clear(); });

describe("system power commands", () => {
  it("offers power actions on all desktop platforms and allows aliases and hotkeys", () => {
    const actions = systemCommandDefinitions("macos").filter(command => command.actions[0].id === systemActionIds.power);
    expect(actions.map(command => command.id)).toEqual(["system:sleep", "system:sleep-displays", "system:restart", "system:shutdown", "system:log-out"]);
    expect(actions.every(command => command.management?.canConfigure && command.management.canDisable)).toBe(true);
    for (const platform of ["windows", "linux"] as const) {
      expect(systemCommandDefinitions(platform).filter(command => command.actions[0].id === systemActionIds.power)).toHaveLength(5);
    }
  });

  it("hides unavailable session actions while retaining suspend and restart", () => {
    const definitions = systemCommandDefinitions("linux", { windowManagement: false, paste: false, sleepDisplays: false, logOut: false, reason: "Wayland" });
    const ids = definitions.map(command => command.id);
    expect(ids).toContain("system:sleep");
    expect(ids).toContain("system:restart");
    expect(ids).not.toContain("system:sleep-displays");
    expect(ids).not.toContain("system:log-out");
    expect(systemCommandDefinitions("unsupported")).toEqual([]);
  });

  it.each([["sleep", "system:sleep"], ["재부팅", "system:restart"], ["전원 끄기", "system:shutdown"], ["로그아웃", "system:log-out"], ["화면 끄기", "system:sleep-displays"]])("finds %s", async (query, id) => {
    for (const platform of ["macos", "windows", "linux"] as const) {
      const results = await createSystemProvider(platform).search(query, new AbortController().signal);
      expect(rankCommands(results, query)[0]?.id, platform).toBe(id);
    }
  });

  it("routes the allowlisted command and locale without shell input", async () => {
    localStorage.setItem("prism:preferences", JSON.stringify({ language: "ko" }));
    vi.mocked(invoke).mockResolvedValue({ applied: false, message: "" });
    expect(await runSystemCommand(systemActionIds.power, systemCommandIds.restart)).toEqual({ applied: false, message: "" });
    expect(invoke).toHaveBeenCalledExactlyOnceWith("run_system_action", { commandId: "system:restart", locale: "ko" });
  });

  it("rejects unknown or mismatched actions before IPC", async () => {
    for (const [action, id] of [[systemActionIds.power, "/usr/bin/pmset"], [systemActionIds.power, systemCommandIds.lockScreen], [systemActionIds.lockScreen, systemCommandIds.restart]]) {
      await expect(runSystemCommand(action, id)).rejects.toThrow();
    }
    expect(invoke).not.toHaveBeenCalled();
  });

  it("preserves native failure details", async () => {
    vi.mocked(invoke).mockRejectedValue({ code: "actionFailed", message: "macOS declined" });
    await expect(runSystemCommand(systemActionIds.power, systemCommandIds.sleep)).rejects.toMatchObject({ code: "actionFailed" });
  });
});
