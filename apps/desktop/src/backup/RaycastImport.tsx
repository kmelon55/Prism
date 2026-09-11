import { AnimatedDetails } from "../settings/InterfaceMotion";
import { useEffect, useRef, useState } from "react";
import { ArrowRight, FileUp, RotateCcw } from "lucide-react";
import { t } from "../i18n";
import { searchNativeApplications, getCommandShortcuts, type NativeApplication } from "../providers/native";
import { getGlobalShortcut } from "../providers/shortcut";
import { getSystemPlatform, getDesktopCapabilities } from "../providers/system";
import { loadLibrary } from "../providers/library";
import { decodeRaycastFile, MAX_RAYCAST_BYTES, RaycastFileError } from "./raycastFile";
import { buildRaycastPlan, raycastApplicationPaths, type ImportItem } from "./raycastPlan";
import { applyRaycastItems, clearMigrationJournal, readMigrationJournal, undoRaycastImport, type AliasAccess, type MigrationJournal } from "./raycastApply";

const categoryNames = { hotkeys: "Hotkeys", aliases: "Aliases", snippets: "Snippets", quicklinks: "Quicklinks" };
export function RaycastImport({ nativeRuntime, aliases, onChanged }: { nativeRuntime: boolean; aliases: AliasAccess; onChanged(): Promise<void> }) {
  const [file, setFile] = useState<File>();
  const [password, setPassword] = useState("");
  const [needsPassword, setNeedsPassword] = useState(false);
  const [rows, setRows] = useState<ImportItem[]>();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [journal, setJournal] = useState<MigrationJournal | null>(null);
  const [ready, setReady] = useState(!nativeRuntime);
  const [confirmForget, setConfirmForget] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const running = useRef(false);
  const mounted = useRef(false);
  const reviewedAt = useRef(0);
  useEffect(() => {
    mounted.current = true;
    if (nativeRuntime) void readMigrationJournal().then(value => { if (mounted.current) { setJournal(value); setReady(true); } }).catch(cause => { if (mounted.current) setError(String(cause)); });
    return () => { mounted.current = false; };
  }, [nativeRuntime]);
  const updateJournal = (value: MigrationJournal) => { if (mounted.current) setJournal(value); };
  async function work(task: () => Promise<void>) {
    if (running.current) return;
    running.current = true; setBusy(true); setError("");
    try { await task(); }
    catch (cause) { if (mounted.current) setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { running.current = false; if (mounted.current) setBusy(false); }
  }
  async function review(selectedFile: File, passphrase?: string) {
    setRows(undefined); setSelected(new Set());
    if (selectedFile.size > MAX_RAYCAST_BYTES) throw new Error("File exceeds 20 MB.");
    let data: unknown;
    try { data = await decodeRaycastFile(new Uint8Array(await selectedFile.arrayBuffer()), passphrase); }
    catch (cause) {
      if (cause instanceof RaycastFileError) {
        if (cause.code === "password") { setNeedsPassword(true); return; }
        throw new Error(({ decrypt: "Incorrect password or damaged file.", size: "File exceeds 20 MB.", version: "This Raycast export version is not supported yet.", invalid: "This file is not a valid Raycast export." })[cause.code]);
      }
      throw new Error("This file is not a valid Raycast export.");
    }
    setPassword(""); setNeedsPassword(false);
    const [apps, library, commands, global] = nativeRuntime ? await Promise.all([searchNativeApplications("", 1000), loadLibrary(), getCommandShortcuts(), getGlobalShortcut()]) : [[], { entries: [] }, [], null];
    const resolvedApps: NativeApplication[] = [...apps];
    if (nativeRuntime) {
      // Root search is capped at 100 results. Resolve exported paths outside that first page too.
      const missing = raycastApplicationPaths(data).filter(path => !resolvedApps.some(app => app.path.normalize("NFC") === path.normalize("NFC")));
      for (let offset = 0; offset < missing.length; offset += 8) {
        const found = await Promise.all(missing.slice(offset, offset + 8).map(path => searchNativeApplications(path.split("/").pop()!.slice(0, -4), 100)));
        for (const app of found.flat()) if (!resolvedApps.some(existing => existing.id === app.id)) resolvedApps.push(app);
      }
    }
    const plan = buildRaycastPlan(data, { apps: resolvedApps, entries: library.entries, aliases: aliases.read(), hotkeys: { ...Object.fromEntries(commands.map(command => [command.commandId, command.accelerator])), ...(global ? { launcher: global.accelerator } : {}) }, disabled: aliases.disabled(), platform: await getSystemPlatform(), capabilities: await getDesktopCapabilities() });
    if (mounted.current) { setRows(plan); setSelected(new Set(plan.filter(row => !row.reason && !row.conflict).map(row => row.id))); reviewedAt.current = Date.now(); }
  }
  const available = rows?.filter(row => !row.reason && !row.conflict).length ?? 0;
  const conflicts = rows?.filter(row => row.conflict && !row.reason).length ?? 0;
  const skipped = rows?.filter(row => row.reason).length ?? 0;
  return <section className="raycast-import" aria-label={t("Import from Raycast")}>
    <div className="raycast-import-heading"><span className="raycast-import-mark"><ArrowRight size={22} /></span><div><h3>{t("Bring your Raycast setup")}</h3><p>{t("Your shortcuts, snippets, and quicklinks. Ready for Prism.")}</p></div></div>
    <input ref={input} type="file" accept=".rayconfig,.json" aria-label={t("Raycast export file")} hidden disabled={busy || Boolean(journal)} onChange={event => {
      const next = event.target.files?.[0]; event.target.value = "";
      if (next) { setFile(next); setPassword(""); setNeedsPassword(false); void work(() => review(next)); }
    }} />
    {!journal && <div className="preference-actions"><button className="prism-primary" disabled={busy || !ready} onClick={() => input.current?.click()}><FileUp size={14} />{t("Choose Raycast export")}</button>{file && <span className="backup-hint">{file.name}</span>}</div>}
    {!file && !journal && <AnimatedDetails><summary>{t("How to export from Raycast")}</summary><ol><li>{t("Run Export Settings & Data in Raycast.")}</li><li>{t("Save the .rayconfig file and remember its export password.")}</li><li>{t("Choose the file here, then review what to bring over.")}</li></ol></AnimatedDetails>}
    {needsPassword && <form className="raycast-password" onSubmit={event => { event.preventDefault(); if (file) { const pass = password; setPassword(""); void work(() => review(file, pass)); } }}><input autoFocus type="password" aria-label={t("Export password")} placeholder={t("Export password")} value={password} onChange={event => setPassword(event.target.value)} autoComplete="off" disabled={busy} /><div className="preference-actions"><button disabled={busy} type="submit">{t("Unlock")}</button></div></form>}
    {rows && !journal && <>
      <div className="raycast-summary"><span><strong>{available}</strong>{t("Ready")}</span><span><strong>{conflicts}</strong>{t("Conflicts")}</span><span><strong>{skipped}</strong>{t("Unsupported")}</span></div>
      <fieldset className="backup-categories" disabled={busy}><legend>{t("Bring over")}</legend>{Object.entries(categoryNames).map(([category, name]) => {
        const candidates = rows.filter(row => row.category === category && !row.reason && !row.conflict);
        return <label key={category}><input type="checkbox" disabled={!candidates.length} checked={candidates.length > 0 && candidates.every(row => selected.has(row.id))} onChange={event => setSelected(current => { const next = new Set(current); candidates.forEach(row => event.target.checked ? next.add(row.id) : next.delete(row.id)); return next; })} />{t(name)}</label>;
      })}</fieldset>
      <div className="raycast-review-list" aria-label={t("Import preview")}>{rows.map(row => <label className="raycast-review-row" key={row.id}><input type="checkbox" disabled={busy || Boolean(row.reason) || Boolean(row.conflict && !row.commandId)} checked={selected.has(row.id)} onChange={event => setSelected(current => { const next = new Set(current); if (event.target.checked) next.add(row.id); else next.delete(row.id); return next; })} /><div><strong>{row.commandId && !row.commandId.startsWith("native:") ? t(row.title) : row.title}</strong><small>{t(categoryNames[row.category])}{row.category === "hotkeys" || row.category === "aliases" ? ` · ${row.value}` : ""}</small></div><span>{row.reason ? t(row.reason) : row.conflict ? t(selected.has(row.id) ? "Replace existing setting" : "Keep existing") : t("Add")}</span></label>)}</div>
      <p>{t("Existing settings stay unless you select a replacement. Unsupported items are skipped.")}</p>
      <div className="preference-actions"><button className="prism-primary" disabled={busy || !nativeRuntime || !selected.size || !ready} onClick={() => void work(async () => {
        if (Date.now() - reviewedAt.current > 10 * 60 * 1000) { setRows(undefined); throw new Error("Review expired. Choose the file again."); }
        await applyRaycastItems(rows.filter(row => selected.has(row.id) && !row.reason), aliases, updateJournal);
        await onChanged();
      })}><ArrowRight size={14} />{t("Import {0} items", { 0: selected.size })}</button><button disabled={busy} onClick={() => { setRows(undefined); setFile(undefined); }}>{t("Cancel")}</button></div>
      <p className="backup-hint">{t("A local recovery copy is saved before import. Quit Raycast before activating the same hotkeys.")}</p>
    </>}
    {journal && <div className="raycast-recovery">
      <h3>{t("Import recovery")}</h3><p>{t("{0} imported · {1} failed · {2} undone", { 0: journal.changes.filter(change => change.state === "applied").length, 1: journal.changes.filter(change => change.state === "failed").length, 2: journal.changes.filter(change => change.state === "undone").length })}</p>
      {journal.changes.some(change => change.state === "pending") && <p role="status">{t("An import was interrupted. Undo can recover changes already written.")}</p>}
      <AnimatedDetails><summary>{t("View results")}</summary><ul>{journal.changes.map(change => <li key={change.item.id}>{change.item.commandId && !change.item.commandId.startsWith("native:") ? t(change.item.title) : change.item.title} · {change.error ? t(change.error) : t(change.state)}</li>)}</ul></AnimatedDetails>
      <div className="preference-actions"><button disabled={busy || journal.changes.every(change => change.state === "undone" || change.state === "failed")} onClick={() => void work(async () => { await undoRaycastImport(journal, aliases, updateJournal); await onChanged(); })}><RotateCcw size={14} />{t("Undo import")}</button>
        <button disabled={busy} onClick={() => { if (!confirmForget) { setConfirmForget(true); return; } void work(async () => { await clearMigrationJournal(journal.id); setJournal(null); setConfirmForget(false); setRows(undefined); setFile(undefined); }); }}>{t(confirmForget ? "Confirm discard recovery" : "Discard recovery")}</button>{confirmForget && <button onClick={() => setConfirmForget(false)}>{t("Cancel")}</button>}</div>
      <p>{t("Undo keeps anything you changed after importing.")}</p>
    </div>}
    {!nativeRuntime && <p className="backup-hint">{t("Preview files here. Apply them in the desktop app.")}</p>}
    {busy && <p role="status">{t("Working…")}</p>}
    {error && <div className="preference-alert" role="alert">{t(error)}</div>}
  </section>;
}
