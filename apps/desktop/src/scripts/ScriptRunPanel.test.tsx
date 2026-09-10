import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { ScriptRunPanel } from "./ScriptRunPanel";
import { getScriptSession } from "./runStore";
import type { ScriptCommandSummary, ScriptRunSnapshot } from "../providers/scripts";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
let root: Root, container: HTMLDivElement, script: ScriptCommandSummary;
let sequence = 0;
const running: ScriptRunSnapshot = { runId: "sr_1", state: "running", result: null, error: null, stdout: "", stderr: "", stdoutTruncated: false, stderrTruncated: false };
beforeEach(() => {
  vi.useFakeTimers();
  Object.defineProperty(navigator, "language", { configurable: true, value: "en" });
  Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
  script = { id: `sc_test_${++sequence}`, title: "My Script", keywords: [], arguments: [] };
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
  native.invoke.mockReset();
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.useRealTimers(); });
async function mount() { await act(async () => root.render(<ScriptRunPanel script={script} onBack={() => {}} />)); }
function button(text: string) { return [...container.querySelectorAll("button")].find((b) => b.textContent === text)!; }
async function click(text: string) { await act(async () => button(text).click()); }
async function type(label: string, value: string) {
  const input = container.querySelector<HTMLInputElement>(`[aria-label="${label}"]`)!;
  await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); });
}
it("never starts on mount, requires args, passes literal values, and clears password drafts", async () => {
  script.arguments = [{ type: "text", placeholder: "Target" }, { type: "password", placeholder: "Secret" }, { type: "text", placeholder: "Optional", optional: true }];
  native.invoke.mockImplementation(async command => command === "list_script_command_runs" ? [] : { ...running, state: "success" });
  await mount(); expect(native.invoke.mock.calls.every(([command]) => command === "list_script_command_runs")).toBe(true); expect(button("Run script").disabled).toBe(true);
  await type("Target", "hello; $(touch nope)"); await type("Secret", "private"); await click("Run script");
  expect(native.invoke).toHaveBeenCalledWith("start_script_command", { scriptId: script.id, args: ["hello; $(touch nope)", "private", ""] });
  expect(container.querySelector<HTMLInputElement>('[aria-label="Secret"]')?.value).toBe("");
  expect(button("Run again").disabled).toBe(true);
});
it("observes output after unmount and restores the completed session without rerunning", async () => {
  native.invoke.mockImplementation(async (command) => command === "start_script_command" ? running : { ...running, state: "success", stdout: "<script>literal</script>", stderr: "warning", stdoutTruncated: true });
  await mount(); await click("Run script");
  await act(async () => root.render(null)); await act(async () => vi.advanceTimersByTimeAsync(160));
  expect(getScriptSession(script.id).snapshot?.state).toBe("success");
  await mount(); expect(container.textContent).toContain("<script>literal</script>"); expect(container.querySelector("script")).toBeNull();
  expect(container.textContent).toContain("warning"); expect(container.textContent).toContain("Output truncated");
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(1);
});
it("requires explicit cancel, surfaces cancel failure, and retries only cancellation", async () => {
  native.invoke.mockImplementation(async (command) => {
    if (command === "cancel_script_command") throw new Error("Cancel unavailable");
    return running;
  });
  await mount(); await click("Run script"); await click("Cancel"); expect(container.textContent).toContain("Cancel unavailable");
  native.invoke.mockImplementation(async (command) => command === "cancel_script_command" ? { ...running, state: "cancelled" } : running);
  await click("Retry cancel"); expect(container.textContent).toContain("Script cancelled");
  await act(async () => vi.advanceTimersByTimeAsync(160));
  expect(getScriptSession(script.id).snapshot?.state).toBe("cancelled");
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(1);
});
it("keeps execution running on observation error and retries status without executing again", async () => {
  native.invoke.mockImplementation(async (command) => { if (command === "start_script_command") return running; throw new Error("Status unavailable"); });
  await mount(); await click("Run script"); await act(async () => vi.advanceTimersByTimeAsync(160));
  expect(container.textContent).toContain("Status unavailable"); expect(button("Run again").disabled).toBe(true);
  native.invoke.mockResolvedValue({ ...running, state: "failure", stderr: "bad input" });
  await click("Retry status check"); await act(async () => vi.advanceTimersByTimeAsync(160));
  expect(container.textContent).toContain("Script failed"); expect(container.textContent).toContain("bad input");
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(1);
});

it("shows interrupted terminal output and reruns only through an explicit action", async () => {
  native.invoke.mockResolvedValue({ ...running, state: "interrupted", stdout: "last checkpoint", timeoutSeconds: 120 });
  await mount(); await click("Run script");
  const calls = native.invoke.mock.calls.length;
  await act(async () => root.render(null)); await mount();
  await act(async () => vi.advanceTimersByTimeAsync(500));
  expect(native.invoke.mock.calls).toHaveLength(calls);
  expect(container.textContent).toContain("Script interrupted");
  expect(container.textContent).toContain("Review any side effects");
  expect(container.textContent).toContain("last checkpoint");
  expect(button("Cancel")).toBeUndefined();
  expect(button("Run again").disabled).toBe(false);
  await click("Run again");
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(2);
});

it("shows the recorded timeout and retries saving history without executing again", async () => {
  script.timeoutSeconds = 120;
  native.invoke.mockResolvedValue({ ...running, state: "timedOut", timeoutSeconds: 60, persistenceError: "Disk full" });
  await mount(); await click("Run script");
  expect(container.textContent).toContain("Timeout: 120 seconds");
  expect(container.textContent).toContain("Script timed out after 60 seconds");
  expect(container.textContent).not.toContain("after 10 seconds");
  native.invoke.mockResolvedValue({ ...running, state: "timedOut", timeoutSeconds: 60, persistenceError: null });
  await click("Retry saving history");
  expect(button("Retry saving history")).toBeUndefined();
  expect(native.invoke.mock.calls.filter(([command]) => command === "start_script_command")).toHaveLength(1);
  expect(native.invoke.mock.calls.filter(([command]) => command === "get_script_command_run")).toHaveLength(1);
});

it("explains withheld password output on a restored terminal result", async () => {
  native.invoke.mockResolvedValue({ ...running, state: "success", outputWithheld: true });
  await mount(); await click("Run script");
  expect(container.textContent).toContain("Output was not saved because this script accepts a password argument.");
  expect(container.textContent).toContain("Script succeeded");
});
