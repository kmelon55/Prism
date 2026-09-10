import { useEffect, useId, useRef, useState } from "react";
import { Download, Upload } from "lucide-react";
import { t, useLocale } from "../i18n";
import type { SettingsPreferences } from "../settings/SettingsView";
import { applyBackup, defaultCategories, exportBackup, previewBackup, previewPreferenceAliases, reviewPreferenceAliases, type BackupCategories, type BackupReview, type SafePreferences } from "./backup";
import "./backup.css";

export interface BackupSettingsProps {
  nativeRuntime: boolean;
  preferences: SettingsPreferences;
  /** Persist before resolving; throw on failure. This action is separate from library import. */
  onRestorePreferences: (safe: SafePreferences) => void | Promise<void>;
}
type Operation = "export" | "review" | "apply" | "preferences";
const labels: Record<keyof BackupCategories, string> = { snippets: "Snippets", quicklinks: "Quicklinks", pathLinks: "Path references", favorites: "Favorites", preferences: "Safe preferences" };
export function BackupSettings({ nativeRuntime, preferences, onRestorePreferences }: BackupSettingsProps) {
  useLocale();
  const [categories, setCategories] = useState<BackupCategories>({ ...defaultCategories });
  const [review, setReview] = useState<BackupReview | null>(null);
  const [libraryApplied, setLibraryApplied] = useState(false);
  const [preferencesApplied, setPreferencesApplied] = useState(false);
  const [busy, setBusy] = useState<Operation | null>(null);
  const [error, setError] = useState("");
  const [retry, setRetry] = useState<Operation | null>(null);
  const [status, setStatus] = useState("");
  const running = useRef(false);
  const mounted = useRef(false);
  const heading = useRef<HTMLHeadingElement>(null);
  const reviewId = useId();
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  useEffect(() => { if (review) heading.current?.focus(); }, [review]);
  async function execute(operation: Operation) {
    if (running.current || !nativeRuntime) return;
    running.current = true; setBusy(operation); setError(""); setRetry(null); setStatus("");
    try {
      if (operation === "export") {
        if (await exportBackup(categories, preferences) && mounted.current) setStatus("Backup saved.");
      } else if (operation === "review") {
        setReview(null); setLibraryApplied(false); setPreferencesApplied(false);
        const next = await previewBackup(categories);
        if (mounted.current) setReview(next);
      } else if (operation === "apply" && review && !libraryApplied) {
        await applyBackup(review.token);
        if (mounted.current) { setLibraryApplied(true); setStatus("Library restored. Existing items were kept."); }
      } else if (operation === "preferences" && review?.preferences && !preferencesApplied) {
        await onRestorePreferences(review.preferences);
        if (mounted.current) { setPreferencesApplied(true); setStatus("Safe preferences restored."); }
      }
    } catch (cause) {
      if (mounted.current) {
        setError(cause instanceof Error ? cause.message : String(cause));
        // Native apply consumes its token on every attempt; never replay a failed mutation.
        if (operation === "apply") { setReview(null); setRetry("review"); }
        else setRetry(operation);
      }
    } finally { running.current = false; if (mounted.current) setBusy(null); }
  }
  const disabled = !nativeRuntime || Boolean(busy);
  const empty = !Object.values(categories).some(Boolean);
  const rows = review ? (["snippets", "quicklinks", "pathLinks", "favorites"] as const).filter(key => categories[key]) : [];
  const aliasPreview = review?.preferences ? previewPreferenceAliases(preferences, review.preferences) : null;
  const additions = review ? rows.reduce((total, key) => total + review.summary[key].added, 0) : 0;
  return <div className="backup-settings">
    <div className="preference-copy"><strong>{t("Local backup")}</strong><span>{t("Choose what to export or import. Existing library items win conflicts.")}</span></div>
    <fieldset disabled={disabled} className="backup-categories"><legend>{t("Backup categories")}</legend>
      {(Object.keys(labels) as (keyof BackupCategories)[]).map(key => <label key={key}><input type="checkbox" checked={categories[key]} onChange={event => {
        setCategories(current => ({ ...current, [key]: event.target.checked })); setReview(null); setError(""); setRetry(null); setStatus("");
      }}/>{t(labels[key])}</label>)}
    </fieldset>
    <p className="backup-hint">{t("Safe preferences include appearance, language, and aliases. Keys, histories, permissions, script folders, and hotkeys are excluded.")}</p>
    <p className="backup-hint">{t("Path references are optional. They restore saved paths only; file search roots and AI access are never granted. Missing targets remain unavailable until repaired.")}</p>
    <p className="backup-hint">{t("Backup files are not encrypted. Keep them somewhere private. Maximum file size: 20 MB.")}</p>
    <div className="preference-actions"><button disabled={disabled || empty} onClick={() => void execute("export")}><Download size={14}/>{t("Export backup")}</button>
      <button disabled={disabled || empty} onClick={() => void execute("review")}><Upload size={14}/>{t("Choose backup to review")}</button></div>
    {review ? <section className="backup-review" aria-labelledby={reviewId}>
      <h3 id={reviewId} ref={heading} tabIndex={-1}>{t("Review backup")}</h3>
      <p className="backup-hint">{t("Only new library items will be added. Missing library favorites are skipped. Review expires after 10 minutes or a library change.")}</p>
      {rows.length ? <table><caption>{t("Selected library categories")}</caption><thead><tr><th scope="col">{t("Category")}</th><th scope="col">{t("In file")}</th><th scope="col">{t("Add")}</th><th scope="col">{t("Conflicts kept")}</th><th scope="col">{t("Skipped")}</th></tr></thead>
        <tbody>{rows.map(key => <tr key={key}><th scope="row">{t(labels[key])}</th><td>{review.summary[key].total}</td><td>{review.summary[key].added}</td><td>{review.summary[key].conflicts}</td><td>{review.summary[key].skipped}</td></tr>)}</tbody></table> : null}
      {review.pathReferences?.length ? <details><summary>{t("Review path targets")}</summary><ul className="backup-reference-list">{review.pathReferences.map(item => <li key={item.id}><strong>{item.title}</strong><code>{item.path}</code><span>{t(item.status === "existing" ? "Target exists" : item.status === "missing" ? "Target missing" : "Target could not be checked")}{item.conflict ? ` · ${t("Existing item kept")}` : ""}</span></li>)}</ul></details> : null}
      {review.missingFavorites?.length ? <details><summary>{t("Favorites skipped because their library targets are missing")}</summary><ul>{review.missingFavorites.map(item => <li key={item.id}>{item.title} <code>{item.id}</code></li>)}</ul></details> : null}
      {rows.length ? <div className="preference-actions"><button disabled={disabled || libraryApplied || additions === 0} onClick={() => void execute("apply")}>{t(libraryApplied ? "Library restored" : "Import new library items")}</button></div> : null}
      {rows.length > 0 && additions === 0 ? <p className="backup-hint">{t("No new library items to import.")}</p> : null}
      {categories.preferences ? review.preferences ? <div className="backup-preferences">
        <strong>{t("Restore safe preferences separately")}</strong>
        <p className="backup-hint">{t("This replaces appearance and language. Existing aliases and alias conflicts are kept. Library import is a separate operation.")}</p>
        <dl><div><dt>{t("Language")}</dt><dd>{t(review.preferences.language === "system" ? "System" : review.preferences.language === "ko" ? "Korean" : "English")}</dd></div>
          <div><dt>{t("Appearance")}</dt><dd>{t(review.preferences.theme === "system" ? "System" : review.preferences.theme === "dark" ? "Dark" : "Light")}</dd></div>
          <div><dt>{t("Background opacity")}</dt><dd>{review.preferences.backgroundOpacity}%</dd></div>
          <div><dt>{t("Background blur")}</dt><dd>{review.preferences.backgroundBlur}</dd></div>
          <div><dt>{t("Reduce motion")}</dt><dd>{t(review.preferences.reduceMotion ? "On" : "Off")}</dd></div>
          <div><dt>{t("Application icons")}</dt><dd>{t(review.preferences.showApplicationIcons ? "On" : "Off")}</dd></div>
          <div><dt>{t("Aliases in backup")}</dt><dd>{aliasPreview?.total}</dd></div></dl>
        {aliasPreview ? <p className="backup-hint">{t("{0} aliases to add · {1} conflicts or capacity skips", { 0: aliasPreview.added, 1: aliasPreview.kept })}</p> : null}
        {aliasPreview?.total ? <details><summary>{t("Review alias changes")}</summary><ul className="backup-reference-list">{reviewPreferenceAliases(preferences, review.preferences).map(item => <li key={item.id}><code>{item.id}</code><span>{item.alias}</span><span>{t(item.status === "add" ? "Add alias" : item.status === "id-conflict" ? "Existing command alias kept" : item.status === "value-conflict" ? "Alias already used; skipped" : "Alias limit reached; skipped")}{item.existingAlias ? `: ${item.existingAlias}` : ""}</span></li>)}</ul></details> : null}
        <div className="preference-actions"><button disabled={disabled || preferencesApplied} onClick={() => void execute("preferences")}>{t(preferencesApplied ? "Safe preferences restored" : "Restore appearance, language, and aliases")}</button></div>
      </div> : <p className="backup-hint">{t("This backup contains no safe preferences.")}</p> : null}
      <div className="preference-actions"><button disabled={Boolean(busy)} onClick={() => { setReview(null); setStatus(""); setError(""); setRetry(null); }}>{t("Close review")}</button></div>
    </section> : null}
    {busy ? <p role="status">{t("Working…")}</p> : status ? <p role="status">{t(status)}</p> : null}
    {error ? <div className="preference-alert" role="alert"><span>{t(error)}</span>{retry ? <button disabled={disabled} onClick={() => void execute(retry)}>{t(retry === "review" ? "Review file again" : retry === "export" ? "Retry export" : "Retry preferences restore")}</button> : null}</div> : null}
    {!nativeRuntime ? <p className="backup-hint">{t("Backup and restore are available in the desktop app.")}</p> : null}
  </div>;
}
