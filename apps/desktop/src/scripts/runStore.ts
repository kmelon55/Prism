import { cancelScriptCommand, getScriptCommandRun, listScriptCommandRuns, startScriptCommand, type ScriptRunSnapshot } from "../providers/scripts";

export interface ScriptSession {
  starting: boolean;
  recovering?: boolean;
  recoveryError?: boolean;
  cancelling: boolean;
  snapshot: ScriptRunSnapshot | null;
  error: string | null;
  errorOperation?: "start" | "cancel" | "observe" | "recover" | "save";
}
const empty: ScriptSession = { starting: false, cancelling: false, snapshot: null, error: null };
const sessions = new Map<string, ScriptSession>();
const listeners = new Set<() => void>();
const polling = new Set<string>();
export const getScriptSession = (scriptId: string): ScriptSession => sessions.get(scriptId) ?? empty;
export function subscribeScriptSessions(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
function publish(scriptId: string, session: ScriptSession) {
  sessions.set(scriptId, session);
  // Bound retained output without discarding any running operation.
  if (sessions.size > 32) {
    const oldest = [...sessions].find(([id, value]) => id !== scriptId && !value.starting && value.snapshot?.state !== "running");
    if (oldest) sessions.delete(oldest[0]);
  }
  listeners.forEach((listener) => listener());
}
function message(error: unknown) { return error instanceof Error ? error.message : String(error); }
const delay = () => new Promise<void>((resolve) => setTimeout(resolve, 150));

/** Polling belongs to the session, not the mounted panel. Errors require explicit retry. */
async function poll(scriptId: string, runId: string) {
  if (polling.has(runId)) return;
  polling.add(runId);
  try {
    while (getScriptSession(scriptId).snapshot?.runId === runId && getScriptSession(scriptId).snapshot?.state === "running") {
      await delay();
      const snapshot = await getScriptCommandRun(runId);
      const current = getScriptSession(scriptId);
      if (current.snapshot?.runId !== runId) return;
      // A stale read must not overwrite a terminal cancellation response.
      if (current.snapshot.state !== "running") return;
      publish(scriptId, { ...current, snapshot, error: current.errorOperation === "cancel" && snapshot.state === "running" ? current.error : null, errorOperation: current.errorOperation === "cancel" && snapshot.state === "running" ? "cancel" : undefined, cancelling: snapshot.state === "running" && current.cancelling });
    }
  } catch (error) {
    const current = getScriptSession(scriptId);
    if (current.snapshot?.runId === runId && current.snapshot.state === "running") publish(scriptId, { ...current, error: message(error), errorOperation: "observe" });
  } finally { polling.delete(runId); }
}

let recovery: Promise<boolean> | undefined;
let recovered = false;

/** A reload must discover existing runs before any explicit start can proceed. */
export function recoverScriptSessions(): Promise<boolean> {
  if (recovered) return Promise.resolve(true);
  if (recovery) return recovery;
  const task = (async () => {
    try {
      const snapshots = await listScriptCommandRuns();
      // Oldest first; the newest retained execution is the panel's session.
      for (const snapshot of [...snapshots].sort((a, b) => a.runId.localeCompare(b.runId))) {
        if (!snapshot.scriptId) continue;
        const current = getScriptSession(snapshot.scriptId);
        if (current.starting || (current.snapshot && current.snapshot.runId > snapshot.runId)) continue;
        publish(snapshot.scriptId, { ...empty, snapshot });
      }
      recovered = true;
      for (const [id, session] of sessions) {
        if (session.recovering || session.recoveryError) publish(id, { ...session, recovering: false, recoveryError: false, error: null, errorOperation: undefined });
        if (session.snapshot?.state === "running") void poll(id, session.snapshot.runId);
      }
      return true;
    } catch (error) {
      for (const [id, session] of sessions) if (session.recovering) publish(id, { ...session, recovering: false, recoveryError: true, error: message(error), errorOperation: "recover" });
      return false;
    } finally { recovery = undefined; }
  })();
  recovery = task;
  return task;
}

export async function recoverScriptSession(scriptId: string) {
  if (recovered) return true;
  publish(scriptId, { ...getScriptSession(scriptId), recovering: true, recoveryError: false, error: null, errorOperation: undefined });
  return recoverScriptSessions();
}

export async function startScriptSession(scriptId: string, args: string[], options: { rerun?: boolean } = {}) {
  if (!await recoverScriptSession(scriptId)) return;
  const current = getScriptSession(scriptId);
  if (current.starting || current.snapshot?.state === "running" || (current.snapshot && !options.rerun)) return;
  publish(scriptId, { ...empty, starting: true });
  try {
    const snapshot = await startScriptCommand(scriptId, args);
    publish(scriptId, { ...empty, snapshot });
    if (snapshot.state === "running") void poll(scriptId, snapshot.runId);
  } catch (error) { publish(scriptId, { ...empty, snapshot: current.snapshot, error: message(error), errorOperation: "start" }); }
}

export async function cancelScriptSession(scriptId: string) {
  const current = getScriptSession(scriptId);
  if (current.cancelling || current.snapshot?.state !== "running") return;
  const runId = current.snapshot.runId;
  publish(scriptId, { ...current, cancelling: true, error: null, errorOperation: undefined });
  try {
    const snapshot = await cancelScriptCommand(runId);
    const latest = getScriptSession(scriptId);
    if (latest.snapshot?.runId !== runId || latest.snapshot.state !== "running") return;
    publish(scriptId, { ...latest, snapshot, error: null, errorOperation: undefined, cancelling: snapshot.state === "running" });
    if (snapshot.state === "running") void poll(scriptId, runId);
  } catch (error) {
    const latest = getScriptSession(scriptId);
    if (latest.snapshot?.runId === runId) publish(scriptId, { ...latest, cancelling: false, error: message(error), errorOperation: "cancel" });
  }
}

export function retryScriptObservation(scriptId: string) {
  const current = getScriptSession(scriptId);
  if (current.snapshot?.state !== "running") return;
  publish(scriptId, { ...current, error: null, errorOperation: undefined });
  void poll(scriptId, current.snapshot.runId);
}

/** Retry only the native checkpoint through a read; never start or cancel a process. */
export async function retryScriptPersistence(scriptId: string) {
  const current = getScriptSession(scriptId);
  if (!current.snapshot) return;
  const runId = current.snapshot.runId;
  try {
    const snapshot = await getScriptCommandRun(runId);
    const latest = getScriptSession(scriptId);
    if (latest.snapshot?.runId !== runId) return;
    // Do not regress terminal state while an older read is in flight.
    if (latest.snapshot.state !== "running" && snapshot.state === "running") return;
    const keepCancellationError = latest.errorOperation === "cancel" && snapshot.state === "running";
    publish(scriptId, { ...latest, snapshot, error: keepCancellationError ? latest.error : null, errorOperation: keepCancellationError ? "cancel" : undefined });
  } catch (error) {
    const latest = getScriptSession(scriptId);
    if (latest.snapshot?.runId === runId) publish(scriptId, { ...latest, error: message(error), errorOperation: "save" });
  }
}
