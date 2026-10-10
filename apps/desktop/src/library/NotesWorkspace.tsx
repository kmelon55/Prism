import { useEffect, useRef, useState } from "react";
import { ArrowLeft, Eye, Pencil, Search, SquarePen, Trash2 } from "lucide-react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { t } from "../i18n";
import type { LibraryEntry } from "../providers/library";
import { isCompositionKey } from "../interaction/usePaletteKeyboard";
import { markdownExcerpt, markdownTitle } from "./noteMarkdown";
import type { NoteSaveStatus } from "./noteAutosave";
import "./notes.css";

export default function NotesWorkspace({
  entries, editor, query, busy, nativeRuntime, status, error, deleting, persisted,
  onQuery, onSelect, onCreate, onEdit, onClose, onRetry, onDelete, onConfirmDelete, onCancelDelete,
}: {
  entries: LibraryEntry[];
  editor: LibraryEntry | null;
  query: string;
  busy: boolean;
  nativeRuntime: boolean;
  status: NoteSaveStatus;
  error: string;
  deleting: boolean;
  persisted: boolean;
  onQuery(value: string): void;
  onSelect(entry: LibraryEntry): void;
  onCreate(): void;
  onEdit(entry: LibraryEntry): void;
  onClose(): void;
  onRetry(): void;
  onDelete(): void;
  onConfirmDelete(): void;
  onCancelDelete(): void;
}) {
  const [preview, setPreview] = useState(false);
  const textarea = useRef<HTMLTextAreaElement>(null);
  const host = useRef<HTMLElement>(null);
  useEffect(() => { setPreview(false); }, [editor?.id]);
  useEffect(() => {
    if (!preview) textarea.current?.focus();
  }, [editor?.id, preview]);
  const active = editor && persisted;
  return <section className="notes-workspace" role="dialog" aria-label={t("Notes")} ref={host}
    onKeyDown={event => {
      if (isCompositionKey(event.nativeEvent)) return;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        if (!busy) onRetry();
      }
      if (event.key === "Tab") {
        const controls = [...host.current!.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),textarea:not(:disabled),[tabindex="0"]')];
        if (event.shiftKey && document.activeElement === controls[0]) { event.preventDefault(); controls.at(-1)?.focus(); }
        else if (!event.shiftKey && document.activeElement === controls.at(-1)) { event.preventDefault(); controls[0]?.focus(); }
      }
    }}>
    <aside className="notes-sidebar">
      <header className="notes-sidebar-header">
        <button aria-label={t("Close notes")} title={t("Back")} onClick={onClose} disabled={busy}><ArrowLeft size={16}/></button>
        <strong>{t("Notes")}</strong>
        <button aria-label={t("New note")} title={t("New note")} onClick={onCreate} disabled={busy || deleting || !nativeRuntime}><SquarePen size={17}/></button>
      </header>
      <label className="notes-search"><Search size={14}/><input aria-label={t("Search notes")} placeholder={t("Search")}
        value={query} onChange={event => onQuery(event.target.value)}/></label>
      <nav className="notes-list" aria-label={t("Notes")}>
        {editor && !active && !query && <button className="notes-list-item" aria-current="true" disabled={busy} onClick={() => textarea.current?.focus()}>
          <strong>{markdownTitle(editor.value) || t("New note")}</strong>
          <span>{markdownExcerpt(editor.value) || "\u00a0"}</span>
        </button>}
        {entries.map(entry => <button key={entry.id} className="notes-list-item" aria-current={entry.id === editor?.id ? "true" : undefined}
          disabled={busy || deleting} onClick={() => onSelect(entry)}>
          <strong>{entry.title}</strong><span>{markdownExcerpt(entry.value) || "\u00a0"}</span>
        </button>)}
        {query && !entries.length && <p className="notes-empty">{t("검색 결과가 없습니다.")}</p>}
      </nav>
    </aside>
    <div className="notes-document">
      <header className="notes-document-toolbar">
        <span className="notes-save-state" role="status">{status === "saving" ? t("Saving…") : ""}</span>
        <button aria-label={t(preview ? "Edit Markdown" : "Preview Markdown")} title={t(preview ? "Edit Markdown" : "Preview Markdown")}
          aria-pressed={preview} disabled={!editor || busy || deleting} onClick={() => setPreview(value => !value)}>{preview ? <Pencil size={16}/> : <Eye size={17}/>}</button>
        <button aria-label={t("Delete note")} title={t("Delete note")} disabled={!active || busy || deleting || !nativeRuntime} onClick={onDelete}><Trash2 size={16}/></button>
      </header>
      {editor ? preview ? <article className="notes-markdown" tabIndex={0} aria-label={t("Markdown preview")} onDoubleClick={() => setPreview(false)}>
        <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{
          img: ({ alt }) => <span>{alt ? `[${alt}]` : "[image]"}</span>,
          a: ({ children, href }) => <a href={href} target="_blank" rel="noreferrer">{children}</a>,
        }}>{editor.value}</Markdown>
      </article> : <textarea ref={textarea} className="notes-writing" aria-label={t("Note content")}
        placeholder={t("Start writing…")} value={editor.value} disabled={busy || deleting || !nativeRuntime}
        spellCheck={false} maxLength={128000}
        onChange={event => onEdit({ ...editor, title: "", value: event.target.value })}/>
        : <div className="notes-blank"/>}
      {deleting && <div className="notes-feedback" role="alert"><span>{t("Delete this note?")}</span>
        <button onClick={onCancelDelete} disabled={busy}>{t("취소")}</button>
        <button onClick={onConfirmDelete} disabled={busy}>{t("삭제")}</button>
      </div>}
      {error && <div className="notes-feedback notes-error" role="alert"><span>{t(error)}</span>
        <button onClick={onRetry} disabled={busy}>{t("Retry save")}</button>
      </div>}
    </div>
  </section>;
}
