import { LibraryEntryEditor } from "./library/LibraryEntryEditor";
import { FileBrowser } from "./library/FileBrowser";
import { LibraryRunDialog, needsLibraryRun } from "./library/LibraryRunDialog";
import { t, t as translate, useLocale, currentLocale } from "./i18n";
import { useEffect, useRef, useState } from "react";
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
export type LibraryTab = "links" | "snippets" | "files" | "favorites";
const tabs: Record<LibraryTab, string> = {
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
    initialEntry?.kind === "snippet" ? "snippets" : initialTab,
  );
  const [showLibraryTabs, setShowLibraryTabs] = useState(initialTab !== "files");
  const [data, setData] = useState<LibraryData>(emptyLibrary);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState(initialQuery);
  const [editor, setEditor] = useState<LibraryEntry | null>(
    initialEntry ?? null,
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
  const dirty = editor && JSON.stringify(editor) !== JSON.stringify(original);
  const refresh = async () => {
    const next = await loadLibrary();
    setData(next);
    onChange();
  };
  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    void loadLibrary()
      .then((v) => {
        if (active) setData(v);
      })
      .catch((e) => {
        if (active) setError(errorText(e));
      });
    return () => {
      active = false;
    };
  }, [nativeRuntime]);
  useEffect(() => {
    input.current?.focus();
  }, [tab, editor?.id, running]);

  function leave() {
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
    await work(async () => {
      await invoke("library_save_entry", { entry: editor });
      setEditor(null);
      setDiscard(false);
    }, t("저장했습니다."));
  }
  function start(entry?: LibraryEntry) {
    const next = entry ?? {
      id: crypto.randomUUID(),
      kind: tab === "snippets" ? "snippet" : "link",
      title: "",
      value: "",
    };
    setEditor(next);
    setOriginal(next);
    setError("");
  }
  const entries = data.entries.filter(
    (e) =>
      (tab === "snippets" ? e.kind === "snippet" : e.kind !== "snippet") &&
      `${e.title} ${e.value}`.toLowerCase().includes(query.toLowerCase()),
  );
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
        <strong>{editor ? t("항목 편집") : t(tabs[tab])}</strong>
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
          setEditor={setEditor}
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
                      aria-label={`${entry.title} ${entry.kind === "snippet" ? t("복사") : t("열기")}`}
                      disabled={busy}
                      onClick={() => {
                        if (needsLibraryRun(entry)) setRunning(entry);
                        else
                          void work(
                            () =>
                              invoke("library_entry_action", {
                                id: entry.id,
                                action:
                                  entry.kind === "snippet" ? "copy" : "open",
                              }),
                            entry.kind === "snippet" ? t("복사했습니다.") : "",
                          );
                      }}
                    >
                      {entry.kind === "snippet" ? (
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
            onClick={() => void work(() => Promise.resolve())}
          >
            {t("다시 불러오기")}
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
