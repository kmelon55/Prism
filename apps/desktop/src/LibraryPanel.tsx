import { LibraryEntryEditor } from "./library/LibraryEntryEditor";
import { FileBrowser } from "./library/FileBrowser";
import { LibraryRunDialog, needsLibraryRun } from "./library/LibraryRunDialog";
import { t, t as translate, useLocale, currentLocale } from "./i18n";
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  ArrowLeft,
  ArrowUp,
  ArrowDown,
  Copy,
  FolderOpen,
  Plus,
  RefreshCw,
  Search,
  Star,
  Trash2,
} from "lucide-react";
import {
  emptyLibrary,
  loadLibrary,
  type LibraryData,
  type LibraryEntry,
} from "./providers/library";
import { isCompositionKey } from "./interaction/usePaletteKeyboard";
import { createNoteAutosave, noteForStorage, type NoteSaveStatus } from "./library/noteAutosave";
import { noteForEditing } from "./library/noteMarkdown";
const NotesWorkspace = lazy(() => import("./library/NotesWorkspace"));
export type LibraryTab = "links" | "snippets" | "notes" | "files" | "favorites";
const tabs: Record<LibraryTab, string> = {
  notes: "Notes",
  links: "링크",
  snippets: "스니펫",
  files: "파일 검색",
  favorites: "즐겨찾기",
};
const errorText = (e: unknown) =>
  typeof e === "string" ? e : t("작업을 완료하지 못했습니다.");

export function LibraryPanel({
  nativeRuntime,
  onClose,
  onChange,
  initialEntry,
  initialTab = "links",
  initialQuery = "",
  initialIncludeSystem = false,
}: {
  nativeRuntime: boolean;
  onClose(): void;
  onChange(): void;
  initialEntry?: LibraryEntry;
  initialTab?: LibraryTab;
  initialQuery?: string;
  initialIncludeSystem?: boolean;
}) {
  useLocale();
  const [tab, setTab] = useState<LibraryTab>(
    initialEntry?.kind === "note" ? "notes" : initialEntry?.kind === "snippet" ? "snippets" : initialEntry ? "links" : initialTab,
  );
  const [showLibraryTabs, setShowLibraryTabs] = useState(Boolean(initialEntry) || initialTab !== "files");
  const [data, setData] = useState<LibraryData>(emptyLibrary);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState(initialQuery);
  const [editor, setEditor] = useState<LibraryEntry | null>(
    initialEntry ? noteForEditing(initialEntry) : null,
  );
  const [original, setOriginal] = useState<LibraryEntry | null>(
    initialEntry ?? null,
  );
  const [discard, setDiscard] = useState(false);
  const [deleting, setDeleting] = useState<string | null>(null);
  const [offset, setOffset] = useState(0);
  const [revision, setRevision] = useState(0);
  const [running, setRunning] = useState<LibraryEntry | null>(null);
  const lock = useRef(false);
  const input = useRef<HTMLInputElement>(null);
  const host = useRef<HTMLElement>(null);
  const noteAutosave = useRef<ReturnType<typeof createNoteAutosave> | null>(null);
  const readGeneration = useRef(0);
  const mounted = useRef(false);
  const [noteSaveStatus, setNoteSaveStatus] = useState<NoteSaveStatus>("idle");
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      // Pending IPC writes continue when another command replaces this surface.
      void noteAutosave.current?.flush();
    };
  }, []);
  const dirty = editor && JSON.stringify(editor) !== JSON.stringify(original);
  const refresh = async () => {
    const generation = ++readGeneration.current;
    const next = await loadLibrary();
    if (generation === readGeneration.current) setData(next);
    onChange();
  };
  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    const generation = readGeneration.current;
    void loadLibrary()
      .then((v) => {
        if (active && generation === readGeneration.current) {
          // The initial read may predate notes already autosaved while it was pending.
          setData(current => ({ ...v, entries: [
            ...current.entries,
            ...v.entries.filter(entry => !current.entries.some(saved => saved.id === entry.id)),
          ] }));
          setLoaded(true);
        }
      })
      .catch((e) => {
        if (active && generation === readGeneration.current) setError(errorText(e));
      });
    return () => {
      active = false;
    };
  }, [nativeRuntime]);
  useEffect(() => {
    input.current?.focus();
  }, [tab, editor?.id, running]);
  useEffect(() => {
    if (tab === "notes" && loaded && !editor && !busy) {
      start(data.entries.find(entry => entry.kind === "note"));
    }
  }, [tab, loaded, editor, busy, data.entries]);

  async function leave() {
    if (busy || running) return;
    if (deleting) {
      setDeleting(null);
      return;
    }
    if (discard) {
      setDiscard(false);
      return;
    }
    if (editor) {
      if (editor.kind === "note") {
        setBusy(true);
        const saved = await (noteAutosave.current?.flush() ?? Promise.resolve(true));
        if (!mounted.current) return;
        setBusy(false);
        if (saved) {
          noteAutosave.current = null;
          onClose();
        }
        return;
      }
      if (dirty) setDiscard(true);
      else setEditor(null);
      return;
    }
    onClose();
  }
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.defaultPrevented || isCompositionKey(e)) return;
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        if (!e.repeat) leave();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  });
  async function work(fn: () => Promise<unknown>, message = "") {
    if (lock.current || !nativeRuntime) return;
    lock.current = true;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await fn();
      await refresh();
      setNotice(message);
    } catch (e) {
      setError(errorText(e));
    } finally {
      lock.current = false;
      setBusy(false);
    }
  }
  async function save() {
    if (!editor) return;
    if (editor.kind === "note") {
      await noteAutosave.current?.flush();
      return;
    }
    await work(async () => {
      await invoke("library_save_entry", { entry: editor });
      setEditor(null);
      setDiscard(false);
    }, t("저장했습니다."));
  }
  function updateEditor(next: LibraryEntry | null) {
    setEditor(next);
    if (next?.kind !== "note" || !nativeRuntime) return;
    if (!noteAutosave.current) {
      noteAutosave.current = createNoteAutosave(editor!, async (snapshot) => {
        const stored = noteForStorage(snapshot, t("New note"));
        await invoke("library_save_entry", { entry: stored });
        if (mounted.current) {
          setData(current => ({ ...current, entries: [stored, ...current.entries.filter(entry => entry.id !== stored.id)] }));
          onChange();
        }
      }, (status, cause) => {
        if (!mounted.current) return;
        setNoteSaveStatus(status);
        setError(status === "error" ? errorText(cause) : "");
      });
    }
    noteAutosave.current.update(next);
  }
  function start(entry?: LibraryEntry) {
    const next: LibraryEntry = entry ? noteForEditing(entry) : {
      id: crypto.randomUUID(),
      kind: tab === "notes" ? "note" : tab === "snippets" ? "snippet" : "link",
      title: "",
      value: "",
    };
    setEditor(next);
    setOriginal(next);
    setError("");
    setNotice("");
    setNoteSaveStatus("idle");
    noteAutosave.current = null;
  }
  async function selectNote(entry?: LibraryEntry) {
    if (lock.current || busy || entry?.id === editor?.id) return;
    lock.current = true;
    setBusy(true);
    try {
      if (!(await (noteAutosave.current?.flush() ?? Promise.resolve(true)))) return;
      if (mounted.current) { start(entry); if (!entry) setQuery(""); }
    } finally {
      lock.current = false;
      if (mounted.current) setBusy(false);
    }
  }
  async function deleteNote() {
    if (!deleting || lock.current || !nativeRuntime) return;
    lock.current = true;
    setBusy(true);
    try {
      if (!(await (noteAutosave.current?.flush() ?? Promise.resolve(true)))) return;
      await invoke("library_delete_entry", { id: deleting });
      await refresh();
      if (mounted.current) {
        noteAutosave.current = null;
        setDeleting(null);
        setEditor(null);
        setError("");
      }
    } catch (cause) {
      if (mounted.current) setError(errorText(cause));
    } finally {
      lock.current = false;
      if (mounted.current) setBusy(false);
    }
  }
  const entries = data.entries.filter(
    (e) =>
      (tab === "notes" ? e.kind === "note" : tab === "snippets" ? e.kind === "snippet" : e.kind === "link" || e.kind === "path") &&
      `${e.title} ${e.value}`.normalize("NFKC").toLowerCase().includes(query.normalize("NFKC").toLowerCase()),
  );
  if (tab === "notes") return <Suspense fallback={<div className="workspace-loading" role="status">{t("Loading…")}</div>}>
    <NotesWorkspace entries={entries} editor={editor} query={query} busy={busy} persisted={data.entries.some(entry => entry.id === editor?.id)} nativeRuntime={nativeRuntime}
      status={noteSaveStatus} error={error} deleting={Boolean(deleting)}
      onQuery={setQuery} onSelect={entry => void selectNote(entry)} onCreate={() => void selectNote()}
      onEdit={updateEditor} onClose={() => void leave()} onRetry={() => void save()}
      onDelete={() => setDeleting(editor?.id ?? null)} onConfirmDelete={() => void deleteNote()} onCancelDelete={() => setDeleting(null)}/>
  </Suspense>;
  if (running)
    return (
      <LibraryRunDialog
        entry={running}
        action={running.kind === "snippet" ? "copy" : "open"}
        nativeRuntime={nativeRuntime}
        onClose={() => setRunning(null)}
        onComplete={() => {
          setRunning(null);
          setNotice(t("완료했습니다."));
        }}
      />
    );
  return (
    <section
      className="library-panel"
      role="dialog"
      aria-label={t("보관함")}
      ref={host}
      onKeyDown={(e) => {
        if (e.key !== "Tab") return;
        const controls = [
          ...host.current!.querySelectorAll<HTMLElement>(
            'button:not(:disabled),input:not(:disabled),textarea:not(:disabled),select:not(:disabled),summary,[tabindex="0"]',
          ),
        ].filter((control) => {
          const disclosure = control.closest("details:not([open])");
          return !disclosure || control.tagName === "SUMMARY";
        });
        if (e.shiftKey && document.activeElement === controls[0]) {
          e.preventDefault();
          controls.at(-1)?.focus();
        } else if (!e.shiftKey && document.activeElement === controls.at(-1)) {
          e.preventDefault();
          controls[0]?.focus();
        }
      }}
    >
      <header className="library-heading">
        <button
          className="icon-button"
          aria-label={t("보관함 닫기")}
          onClick={leave}
        >
          <ArrowLeft size={17} />
        </button>
        <strong>{editor ? t(editor.kind === "note" ? "Edit note" : "항목 편집") : t(tabs[tab])}</strong>
        {editor?.kind === "note" && (noteSaveStatus === "saving" || noteSaveStatus === "saved") && (
          <span className="note-save-status" role="status">{t(noteSaveStatus === "saving" ? "Saving…" : "Saved")}</span>
        )}
        {!editor && initialTab === "files" && <button aria-expanded={showLibraryTabs} onClick={() => setShowLibraryTabs((value) => !value)}>{t("보관함")}</button>}
      </header>
      {!nativeRuntime && (
        <p className="library-feedback">
          {t("보관함 저장과 파일 검색은 macOS 앱에서 사용할 수 있습니다.")}
        </p>
      )}
      {editor ? (
        <LibraryEntryEditor
          editor={editor}
          setEditor={updateEditor}
          busy={busy}
          nativeRuntime={nativeRuntime}
          input={input}
          leave={leave}
          save={save}
          discard={discard}
          setDiscard={setDiscard}
          work={work}
        />
      ) : (
        <>
          {showLibraryTabs && <nav className="library-tabs" aria-label={t("보관함 종류")}>
            {(Object.keys(tabs) as LibraryTab[]).map((t) => (
              <button
                key={t}
                aria-pressed={tab === t}
                onClick={() => {
                  setTab(t);
                  setQuery("");
                  setOffset(0);
                  setDeleting(null);
                }}
              >
                {translate(tabs[t])}
              </button>
            ))}
          </nav>}
          <div className="library-toolbar">
            <label>
              <Search size={15} />
              <input
                ref={input}
                aria-label={t("보관함 검색")}
                onKeyDown={(event) => {
                  if (
                    tab === "files" &&
                    !isCompositionKey(event.nativeEvent) &&
                    (event.key === "ArrowDown" || event.key === "ArrowUp")
                  ) {
                    event.preventDefault();
                    host.current
                      ?.querySelector<HTMLElement>('[role="listbox"]')
                      ?.focus();
                  }
                }}
                value={query}
                placeholder={tab === "files" ? t("파일 이름 검색") : t("검색")}
                onChange={(e) => {
                  setQuery(e.target.value);
                  setOffset(0);
                }}
              />
            </label>
            {tab === "links" || tab === "snippets" ? (
              <button onClick={() => start()} disabled={!nativeRuntime}>
                <Plus size={15} />
                {t("추가")}
              </button>
            ) : tab === "files" ? (
              <>
                <button
                  disabled={busy || !nativeRuntime}
                  onClick={() =>
                    void work(async () => {
                      await invoke("library_refresh_files");
                      setRevision((v) => v + 1);
                    }, t("파일 목록을 갱신하고 있습니다. 검색 결과가 추가될 수 있습니다."))
                  }
                  aria-label={t("파일 목록 새로고침")}
                >
                  <RefreshCw size={15} />
                </button>
              </>
            ) : null}
          </div>
          <div className="library-content">
            {tab === "files" ? (
              <FileBrowser
                initialIncludeSystem={initialIncludeSystem}
                nativeRuntime={nativeRuntime}
                query={query}
                offset={offset}
                revision={revision}
                roots={data.roots}
                busy={busy}
                onOffset={setOffset}
                onAddRoot={() => void work(() => invoke("library_add_root", { locale: currentLocale() }))}
                onRemoveRoot={(id) =>
                  void work(() => invoke("library_remove_root", { id }))
                }
                onAction={(id, action) =>
                  void work(
                    () => invoke("library_file_action", { id, action }),
                    action === "copy" ? t("경로를 복사했습니다.") : "",
                  )
                }
              />
            ) : tab === "favorites" ? (
              <>
                {data.favorites.map((f, i) => (
                  <div className="library-row" key={f.id}>
                    <Star size={14} />
                    <strong>{f.title}</strong>
                    {[-1, 1].map((direction) => (
                      <button
                        key={direction}
                        aria-label={`${f.title} ${direction < 0 ? t("위로") : t("아래로")}`}
                        disabled={
                          busy ||
                          i + direction < 0 ||
                          i + direction >= data.favorites.length
                        }
                        onClick={() =>
                          void work(() => {
                            const ids = data.favorites.map((f) => f.id);
                            [ids[i], ids[i + direction]] = [
                              ids[i + direction],
                              ids[i],
                            ];
                            return invoke("library_reorder_favorites", { ids });
                          })
                        }
                      >
                        {direction < 0 ? (
                          <ArrowUp size={14} />
                        ) : (
                          <ArrowDown size={14} />
                        )}
                      </button>
                    ))}
                    <button
                      aria-label={t("{0} 즐겨찾기 해제", { "0": f.title })}
                      disabled={busy}
                      onClick={() =>
                        void work(() =>
                          invoke("library_set_favorite", {
                            favorite: f,
                            enabled: false,
                          }),
                        )
                      }
                    >
                      <Trash2 size={14} />
                    </button>
                  </div>
                ))}
                {!data.favorites.length && (
                  <p>{t("검색 결과의 더 보기에서 즐겨찾기를 추가하세요.")}</p>
                )}
              </>
            ) : (
              <>
                {entries.map((entry) => (
                  <div key={entry.id} className="library-row">
                    <button
                      className="library-row-main"
                      onClick={() => start(entry)}
                    >
                      <strong>{entry.title}</strong>
                      <small>{entry.value}</small>
                    </button>
                    <button
                      aria-label={`${entry.title} ${(entry.kind === "snippet" || entry.kind === "note") ? t("복사") : t("열기")}`}
                      disabled={busy}
                      onClick={() => {
                        if (needsLibraryRun(entry)) setRunning(entry);
                        else
                          void work(
                            () =>
                              invoke("library_entry_action", {
                                id: entry.id,
                                action:
                                  (entry.kind === "snippet" || entry.kind === "note") ? "copy" : "open",
                              }),
                            (entry.kind === "snippet" || entry.kind === "note") ? t("복사했습니다.") : "",
                          );
                      }}
                    >
                      {(entry.kind === "snippet" || entry.kind === "note") ? (
                        <Copy size={14} />
                      ) : (
                        <FolderOpen size={14} />
                      )}
                    </button>
                    <button
                      aria-label={t("{0} 삭제", { "0": entry.title })}
                      onClick={() => setDeleting(entry.id)}
                    >
                      <Trash2 size={14} />
                    </button>
                  </div>
                ))}
                {!entries.length && (
                  <p>
                    {query
                      ? t("검색 결과가 없습니다.")
                      : t("자주 쓰는 항목을 추가하세요.")}
                  </p>
                )}
              </>
            )}
          </div>
          {deleting && (
            <div className="library-confirm" role="alert">
              <span>{t("이 항목을 삭제할까요?")}</span>
              <button
                disabled={busy}
                onClick={() =>
                  void work(async () => {
                    await invoke("library_delete_entry", { id: deleting });
                    setDeleting(null);
                  })
                }
              >
                {t("삭제")}
              </button>
              <button disabled={busy} onClick={() => setDeleting(null)}>
                {t("취소")}
              </button>
            </div>
          )}
        </>
      )}

      {error && (
        <div className="library-feedback error" role="alert">
          {t(error)}
          <button
            disabled={busy}
            onClick={() => editor?.kind === "note" ? void save() : void work(() => Promise.resolve())}
          >
            {t(editor?.kind === "note" ? "Retry save" : "다시 불러오기")}
          </button>
        </div>
      )}
      {notice && (
        <div className="library-feedback" role="status">
          {t(notice)}
        </div>
      )}
    </section>
  );
}
