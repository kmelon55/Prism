import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ArrowLeft } from "lucide-react";
import { t, useLocale } from "../i18n";
import { isCompositionKey } from "../interaction/usePaletteKeyboard";
import type { LibraryEntry } from "../providers/library";
import { libraryError } from "./useFileBrowser";

export type LibraryRunAction = "open" | "copy" | "paste";
export function needsLibraryRun(entry: LibraryEntry): boolean {
  return entry.kind === "link"
    ? entry.value.includes("{query}")
    : entry.kind === "snippet" &&
        /\{(?:date|time|clipboard)\}/.test(entry.value);
}
interface PreparedEntry {
  token: string;
  value: string;
}
export interface LibraryRunDialogProps {
  entry: LibraryEntry;
  action: LibraryRunAction;
  nativeRuntime: boolean;
  onClose(): void;
  onComplete(action: LibraryRunAction): void;
}

export function LibraryRunDialog({
  entry,
  action,
  nativeRuntime,
  onClose,
  onComplete,
}: LibraryRunDialogProps) {
  useLocale();
  const [query, setQuery] = useState("");
  const [revision, setRevision] = useState(0);
  const [prepared, setPrepared] = useState<
    (PreparedEntry & { key: string }) | null
  >(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const host = useRef<HTMLElement>(null);
  const lock = useRef(false);
  const mounted = useRef(true);
  const key = JSON.stringify([entry.id, entry.value, query, revision]);
  const needsQuery = entry.kind === "link" && entry.value.includes("{query}");
  const label =
    action === "open"
      ? t("열기")
      : action === "paste"
        ? t("붙여넣기")
        : t("복사");

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useEffect(() => {
    host.current
      ?.querySelector<HTMLElement>(needsQuery ? "input" : "button")
      ?.focus();
  }, [entry.id, needsQuery]);
  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    setPrepared(null);
    if (!nativeRuntime || (needsQuery && !query.trim())) {
      setLoading(false);
      return;
    }
    const timer = window.setTimeout(
      () => {
        void invoke<PreparedEntry>("library_prepare_entry", {
          id: entry.id,
          query: needsQuery ? query : null,
        })
          .then((result) => {
            if (active) setPrepared({ ...result, key });
          })
          .catch((reason) => {
            if (active) setError(libraryError(reason));
          })
          .finally(() => {
            if (active) setLoading(false);
          });
      },
      needsQuery ? 150 : 0,
    );
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [key, nativeRuntime, needsQuery, entry.id, query]);

  async function execute() {
    if (!prepared || prepared.key !== key || lock.current || !nativeRuntime)
      return;
    lock.current = true;
    setBusy(true);
    setError("");
    try {
      await invoke("library_run_entry", {
        id: entry.id,
        action,
        token: prepared.token,
      });
      if (mounted.current) onComplete(action);
    } catch (reason) {
      if (mounted.current) {
        setError(libraryError(reason));
        setPrepared(null);
      }
    } finally {
      lock.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  const ready = prepared?.key === key ? prepared : null;
  return (
    <section
      className="library-run-dialog"
      ref={host}
      role="dialog"
      aria-modal="true"
      aria-label={entry.title}
      onKeyDown={(event) => {
        if (isCompositionKey(event.nativeEvent)) return;
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          if (!busy && !event.repeat) onClose();
        }
        if (event.key === "Tab") {
          const controls = [
            ...host.current!.querySelectorAll<HTMLElement>(
              "button:not(:disabled), input:not(:disabled)",
            ),
          ];
          if (event.shiftKey && document.activeElement === controls[0]) {
            event.preventDefault();
            controls.at(-1)?.focus();
          } else if (
            !event.shiftKey &&
            document.activeElement === controls.at(-1)
          ) {
            event.preventDefault();
            controls[0]?.focus();
          }
        }
      }}
    >
      <header className="library-heading">
        <button
          className="icon-button"
          aria-label={t("취소")}
          disabled={busy}
          onClick={onClose}
        >
          <ArrowLeft size={17} />
        </button>
        <strong>{entry.title}</strong>
      </header>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void execute();
        }}
      >
        {needsQuery && (
          <label>
            {t("검색어")}
            <input
              aria-label={t("검색어")}
              value={query}
              maxLength={2048}
              disabled={busy}
              onChange={(event) => setQuery(event.target.value)}
            />
          </label>
        )}
        {loading && <p role="status">{t("미리보기를 불러오는 중…")}</p>}
        {ready && (
          <pre className="library-run-preview" aria-label={t("실행 미리보기")}>
            {ready.value}
          </pre>
        )}
        {error && <p role="alert">{t(error)}</p>}
        {!nativeRuntime && (
          <p>
            {t("보관함 저장과 파일 검색은 macOS 앱에서 사용할 수 있습니다.")}
          </p>
        )}
        <div className="library-buttons">
          <button
            type="button"
            disabled={busy || loading || !nativeRuntime}
            onClick={() => setRevision((value) => value + 1)}
          >
            {t("미리보기 새로고침")}
          </button>
          <button type="submit" disabled={busy || loading || !ready}>
            {label}
          </button>
        </div>
      </form>
    </section>
  );
}
