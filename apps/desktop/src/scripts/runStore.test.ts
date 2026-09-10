import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ScriptRunSnapshot } from "../providers/scripts";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
const running: ScriptRunSnapshot = { scriptId: "sc_a", runId: "sr_0000000000000001", state: "running", result: null, error: null, stdout: "before reload", stderr: "", stdoutTruncated: false, stderrTruncated: false };
beforeEach(() => {
  vi.resetModules(); vi.useFakeTimers(); native.invoke.mockReset();
  Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });
it("reattaches after renderer module reload, polls completion, and never duplicates execution", async () => {
  const store = await import("./runStore");
  native.invoke.mockImplementation(async command => command === "list_script_command_runs" ? [running] : { ...running, state: "success", stdout: "finished" });
  await Promise.all([store.recoverScriptSession("sc_a"), store.startScriptSession("sc_a", [])]);
  expect(native.invoke.mock.calls.filter(([command]) => command === "list_script_command_runs")).toHaveLength(1);
  expect(store.getScriptSession("sc_a").snapshot?.stdout).toBe("before reload");
  expect(native.invoke.mock.calls.some(([command]) => command === "start_script_command")).toBe(false);
  await vi.advanceTimersByTimeAsync(160);
  expect(store.getScriptSession("sc_a").snapshot?.state).toBe("success");
  vi.resetModules();
  const reloaded = await import("./runStore");
  native.invoke.mockResolvedValue([{ ...running, state: "success", stdout: "finished" }]);
  await reloaded.recoverScriptSession("sc_a");
  expect(reloaded.getScriptSession("sc_a").snapshot?.stdout).toBe("finished");
  expect(native.invoke.mock.calls.some(([command]) => command === "start_script_command")).toBe(false);
});
it("blocks execution on failed recovery and requires an explicit observation retry", async () => {
  const store = await import("./runStore");
  native.invoke.mockRejectedValue(new Error("Registry unavailable"));
  await store.startScriptSession("sc_a", ["private"]);
  expect(store.getScriptSession("sc_a")).toMatchObject({ recoveryError: true, error: "Registry unavailable" });
  expect(native.invoke.mock.calls.map(([command]) => command)).toEqual(["list_script_command_runs"]);
  native.invoke.mockResolvedValue([{ ...running, state: "cancelled" }]);
  await store.recoverScriptSession("sc_a");
  expect(store.getScriptSession("sc_a").snapshot?.state).toBe("cancelled");
  expect(store.getScriptSession("sc_a").error).toBeNull();
  expect(native.invoke.mock.calls.some(([command]) => command === "start_script_command")).toBe(false);
});
it("waits for registry recovery before simultaneous explicit starts and starts exactly once", async () => {
  const store = await import("./runStore");
  let resolveList: (value: ScriptRunSnapshot[]) => void = () => {};
  native.invoke.mockImplementation(command => command === "list_script_command_runs" ? new Promise(resolve => { resolveList = resolve; }) : Promise.resolve(running));
  const first = store.startScriptSession("sc_a", []);
  const second = store.startScriptSession("sc_a", []);
  expect(native.invoke.mock.calls.map(([command]) => command)).toEqual(["list_script_command_runs"]);
  resolveList([]); await Promise.all([first, second]);
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(1);
});
it("cancels only the recovered target and ignores an older in-flight observation", async () => {
  const store = await import("./runStore");
  let resolveRead: (value: ScriptRunSnapshot) => void = () => {};
  const other = { ...running, scriptId: "sc_b", runId: "sr_0000000000000002" };
  native.invoke.mockImplementation((command, args) => {
    if (command === "list_script_command_runs") return Promise.resolve([running, other]);
    if (command === "cancel_script_command") return Promise.resolve({ ...running, state: "cancelled" });
    if (args.runId === running.runId) return new Promise(resolve => { resolveRead = resolve; });
    return Promise.resolve(other);
  });
  await store.recoverScriptSession("sc_a"); await vi.advanceTimersByTimeAsync(150);
  await store.cancelScriptSession("sc_a"); resolveRead(running); await Promise.resolve();
  expect(native.invoke.mock.calls.filter(([command]) => command === "cancel_script_command")).toEqual([["cancel_script_command", { runId: running.runId }]]);
  expect(store.getScriptSession("sc_a").snapshot?.state).toBe("cancelled");
  expect(store.getScriptSession("sc_b").snapshot?.state).toBe("running");
});

it("restores a completed run on command entry and reruns only on explicit Run again", async () => {
  const store = await import("./runStore");
  native.invoke.mockImplementation(async command => command === "list_script_command_runs" ? [{ ...running, state: "success" }] : { ...running, runId: "sr_0000000000000002" });
  await store.recoverScriptSession("sc_a");
  await store.startScriptSession("sc_a", []);
  expect(native.invoke.mock.calls.some(([command]) => command === "start_script_command")).toBe(false);
  expect(store.getScriptSession("sc_a").snapshot?.state).toBe("success");
  await store.startScriptSession("sc_a", [], { rerun: true });
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(1);
});

it("restores interrupted runs as terminal and does not poll, cancel, or automatically rerun", async () => {
  const store = await import("./runStore");
  native.invoke.mockResolvedValue([{ ...running, state: "interrupted", stdout: "last durable checkpoint" }]);
  await store.recoverScriptSession("sc_a");
  await store.startScriptSession("sc_a", []);
  await store.cancelScriptSession("sc_a");
  await vi.advanceTimersByTimeAsync(1000);
  expect(store.getScriptSession("sc_a").snapshot?.state).toBe("interrupted");
  expect(native.invoke.mock.calls.map(([command]) => command)).toEqual(["list_script_command_runs"]);
});

it("retries failed terminal persistence with a status read only", async () => {
  const store = await import("./runStore");
  native.invoke.mockResolvedValue([{ ...running, state: "timedOut", persistenceError: "Disk full" }]);
  await store.recoverScriptSession("sc_a");
  native.invoke.mockRejectedValueOnce(new Error("Bridge unavailable"));
  await store.retryScriptPersistence("sc_a");
  expect(store.getScriptSession("sc_a").errorOperation).toBe("save");
  native.invoke.mockResolvedValueOnce({ ...running, state: "timedOut", persistenceError: null });
  await store.retryScriptPersistence("sc_a");
  expect(store.getScriptSession("sc_a")).toMatchObject({ error: null, snapshot: { state: "timedOut", persistenceError: null } });
  expect(native.invoke.mock.calls.map(([command]) => command)).toEqual(["list_script_command_runs", "get_script_command_run", "get_script_command_run"]);
});

it("keeps a cancellation error visible across successful running-status polls", async () => {
  const store = await import("./runStore");
  native.invoke.mockImplementation(async command => {
    if (command === "list_script_command_runs") return [running];
    if (command === "cancel_script_command") throw new Error("Cancel unavailable");
    return running;
  });
  await store.recoverScriptSession("sc_a");
  await store.cancelScriptSession("sc_a");
  await vi.advanceTimersByTimeAsync(160);
  expect(store.getScriptSession("sc_a")).toMatchObject({ error: "Cancel unavailable", errorOperation: "cancel", cancelling: false });
  expect(native.invoke.mock.calls.some(([command]) => command === "start_script_command")).toBe(false);
});
