import { useRef, useState } from "react";
import { t, useLocale } from "../i18n";
import type { PreferencesRecoveryReview } from "./preferencesPersistence";

/** App owns refreshing the single-use review after failure and persisting before updating state. */
export function PreferencesRecovery({ review, onRecover, onReviewAgain }: {
  review: PreferencesRecoveryReview | null;
  onRecover: () => void | Promise<void>;
  onReviewAgain: () => void;
}) {
  useLocale();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [error, setError] = useState("");
  const running = useRef(false);
  async function recover() {
    if (running.current || !review) return;
    running.current = true; setBusy(true); setError("");
    try { await onRecover(); } catch (cause) { setFailed(true); setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { running.current = false; setBusy(false); }
  }
  return <section className="backup-review" aria-label={t("Recover local settings")}>
    <strong>{t("Local settings could not be read")}</strong>
    <p>{t("Temporary defaults are in use. Your stored settings have been preserved. Recovery restores only appearance, language, and aliases.")}</p>
    {review ? <><details><summary>{t("Review last-known-good settings")}</summary><dl>
      <dt>{t("Language")}</dt><dd>{t(review.preferences.language === "ko" ? "Korean" : review.preferences.language === "en" ? "English" : "System")}</dd>
      <dt>{t("Appearance")}</dt><dd>{t(review.preferences.theme === "dark" ? "Dark" : review.preferences.theme === "light" ? "Light" : "System")}</dd>
      <dt>{t("Background opacity")}</dt><dd>{review.preferences.backgroundOpacity}%</dd>
      <dt>{t("Background blur")}</dt><dd>{review.preferences.backgroundBlur}</dd>
      <dt>{t("Reduce motion")}</dt><dd>{t(review.preferences.reduceMotion ? "On" : "Off")}</dd>
      <dt>{t("Application icons")}</dt><dd>{t(review.preferences.showApplicationIcons ? "On" : "Off")}</dd>
      <dt>{t("Aliases in backup")}</dt><dd>{Object.entries(review.preferences.commandAliases).map(([id, alias]) => <div key={id}><code>{id}</code>: {alias}</div>)}</dd>
    </dl></details><button disabled={busy || failed} onClick={() => void recover()}>{t("Recover last-known-good settings")}</button></> : <p>{t("No valid settings snapshot is available. You can review a backup file to restore safe preferences.")}</p>}
    {error ? <p role="alert">{t(error)}</p> : null}
    <button disabled={busy} onClick={() => { setFailed(false); setError(""); onReviewAgain(); }}>{t("Review recovery again")}</button>
  </section>;
}
