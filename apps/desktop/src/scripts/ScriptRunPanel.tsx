import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { ArrowLeft, Play, Square, RotateCcw } from "lucide-react";
import { isCompositionKey } from "../interaction/usePaletteKeyboard";
import { t, useLocale } from "../i18n";
import type { ScriptCommandSummary } from "../providers/scripts";
import { cancelScriptSession, getScriptSession, recoverScriptSession, retryScriptObservation, retryScriptPersistence, startScriptSession, subscribeScriptSessions } from "./runStore";

export interface ScriptRunPanelProps { script: ScriptCommandSummary; onBack: () => void }

export function ScriptRunPanel(props: ScriptRunPanelProps) {
  return <ScriptRunPanelContent key={props.script.id} {...props} />;
}
function ScriptRunPanelContent({ script, onBack }: ScriptRunPanelProps) {
  useLocale();
  const host = useRef<HTMLElement>(null);
  const composing = useRef(false);
  useEffect(() => { host.current?.querySelector<HTMLElement>("input:not(:disabled), select:not(:disabled), button")?.focus(); }, [script.id]);
  useEffect(() => { void recoverScriptSession(script.id); }, [script.id]);
  const fields = script.arguments ?? [];
  const [args, setArgs] = useState(() => fields.map(() => ""));
  const session = useSyncExternalStore(subscribeScriptSessions, () => getScriptSession(script.id));
  const { snapshot } = session;
  const busy = session.recovering || session.starting || snapshot?.state === "running";
  const invalid = Boolean(script.argumentError) || fields.some((field, index) => !field.optional && !args[index]);
  const status = session.recovering ? t("Restoring script run…") : session.starting ? t("Starting script…") : snapshot?.state === "running" ? t("Running")
    : snapshot?.state === "success" ? t("Script succeeded") : snapshot?.state === "cancelled" ? t("Script cancelled")
    : snapshot?.state === "interrupted" ? t("Script interrupted") : snapshot?.state === "timedOut" || snapshot?.result?.timedOut ? t("Script timed out")
    : snapshot?.state === "failure" ? t("Script failed") : t("Ready to run");
  const submit = () => {
    if (busy || invalid || session.recoveryError) return;
    void startScriptSession(script.id, args, { rerun: true });
    // Do not retain password arguments for retry or panel restoration.
    setArgs((values) => values.map((value, index) => fields[index].type === "password" ? "" : value));
  };
  return <section className="script-run-panel" aria-label={t("Script command")} ref={host}
    onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }}
    onKeyDown={(event) => {
      if (composing.current || isCompositionKey(event.nativeEvent)) return;
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); if (!event.repeat) onBack(); }
    }}>
    <header className="script-run-header">
      <button type="button" onClick={onBack} aria-label={t("Back")}><ArrowLeft size={16} /></button>
      <div><h2>{script.title}</h2>{script.description ? <p>{script.description}</p> : null}</div>
    </header>
    <form className="script-run-form" onSubmit={(event) => { event.preventDefault(); if (!composing.current) submit(); }}>
      {fields.map((field, index) => <label className="script-argument" key={index}>
        <span>{field.placeholder}{field.optional ? <small>{t("Optional")}</small> : null}</span>
        {field.type === "dropdown" ? <select aria-label={field.placeholder} value={args[index]} required={!field.optional} disabled={busy} onChange={(event) => setArgs((values) => values.map((value, i) => i === index ? event.target.value : value))}>
          <option value="">{t("Choose an option")}</option>
          {field.data?.map((option, i) => <option key={i} value={option.value}>{option.title}</option>)}
        </select> : <input aria-label={field.placeholder} type={field.type} value={args[index]} required={!field.optional} disabled={busy} maxLength={8192} autoComplete="off" spellCheck={false}
          onChange={(event) => setArgs((values) => values.map((value, i) => i === index ? event.target.value : value))} />}
      </label>)}
      {script.argumentError ? <p role="alert">{t("Invalid script metadata. Fix the script and refresh commands.")}</p> : null}
      <p>{t("Timeout: {0} seconds", { 0: script.timeoutSeconds ?? 10 })}</p>
      <div className="script-run-actions">
        <button type="submit" disabled={busy || invalid || session.recoveryError}>{snapshot || session.error ? <RotateCcw size={14} /> : <Play size={14} />}{session.errorOperation === "start" ? t("Retry start") : snapshot ? t("Run again") : t("Run script")}</button>
        {snapshot?.state === "running" ? <button type="button" disabled={session.cancelling} onClick={() => void cancelScriptSession(script.id)}><Square size={14} />{session.cancelling ? t("Cancelling…") : session.errorOperation === "cancel" ? t("Retry cancel") : t("Cancel")}</button> : null}
      </div>
    </form>
    <div className="script-run-status" role="status" data-state={snapshot?.state ?? "ready"}>
      <strong>{status}</strong>
      {snapshot?.result ? <span>{t("{0} ms", { 0: snapshot.result.durationMs })}{snapshot.result.exitCode !== null ? ` · ${t("Exit code {0}", { 0: snapshot.result.exitCode })}` : ""}</span> : null}
      {snapshot?.result?.timedOut || snapshot?.state === "timedOut" ? <p>{t("Script timed out after {0} seconds", { 0: snapshot.timeoutSeconds ?? script.timeoutSeconds ?? 10 })}</p> : null}
      {snapshot?.state === "interrupted" ? <p>{t("This run was interrupted by a Prism restart. Review any side effects before running again.")}</p> : null}
      {busy ? <p>{t("You can go back while the script runs.")}</p> : null}
    </div>
    {session.error || snapshot?.error ? <div className="script-run-error" role="alert"><p>{t(session.error ?? snapshot?.error ?? "")}</p>
      {session.recoveryError ? <button type="button" onClick={() => void recoverScriptSession(script.id)}>{t("Retry status check")}</button> : null}
      {session.error && session.errorOperation === "observe" && snapshot?.state === "running" ? <button type="button" onClick={() => retryScriptObservation(script.id)}>{t("Retry status check")}</button> : null}
    </div> : null}
    {snapshot?.persistenceError || session.errorOperation === "save" ? <div className="script-run-error" role="alert">
      <p>{t("Run history could not be saved. Execution will not be repeated.")}</p>
      {snapshot?.persistenceError ? <p>{snapshot.persistenceError}</p> : null}
      <button type="button" onClick={() => void retryScriptPersistence(script.id)}>{t("Retry saving history")}</button>
    </div> : null}
    {snapshot?.outputWithheld ? <p>{t("Output was not saved because this script accepts a password argument.")}</p> : null}
    {snapshot ? <div className="script-run-output">{(["stdout", "stderr"] as const).map((stream) => <section key={stream} aria-label={stream === "stdout" ? t("Standard output") : t("Standard error")}>
      <h3>{stream === "stdout" ? t("Standard output") : t("Standard error")}</h3>
      <pre tabIndex={0}>{snapshot[stream] || t("No output yet.")}</pre>
      {snapshot[stream === "stdout" ? "stdoutTruncated" : "stderrTruncated"] ? <p>{t("Output truncated at 64 KiB.")}</p> : null}
    </section>)}</div> : null}
  </section>;
}
