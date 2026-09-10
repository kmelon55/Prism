import { useEffect, useState } from "react";
import { File, Image, Type } from "lucide-react";
import { t, useLocale } from "../i18n";
import { getClipboardHistoryEntryPreview, getClipboardHistoryEntryText, type ClipboardPreviewMetadata } from "../providers/clipboard";
import { isTauriRuntime } from "../providers/native";

type Preview = { id: number; kind: string; value?: string; error?: string };

export function ClipboardEntryPreview({ entry }: { entry: ClipboardPreviewMetadata & { id?: number; content?: string; capturedAt?: number } }) {
  useLocale();
  const kind = entry.kind ?? "text";
  const id = entry.id;
  const native = isTauriRuntime();
  const [retry, setRetry] = useState(0);
  const [preview, setPreview] = useState<Preview | null>(null);
  useEffect(() => {
    let cancelled = false;
    setPreview(null);
    if ((kind === "image" || kind === "text") && id !== undefined && native) {
      const load = kind === "image" ? getClipboardHistoryEntryPreview : getClipboardHistoryEntryText;
      void load(id).then((value) => {
        if (!cancelled) setPreview({ id, kind, value });
      }).catch((cause: unknown) => {
        if (!cancelled) setPreview({ id, kind, error: String(cause) });
      });
    }
    return () => { cancelled = true; };
  }, [kind, id, native, retry]);
  const current = preview?.id === id && preview?.kind === kind ? preview : null;
  const content = kind === "text" ? current?.value ?? entry.content : entry.content;
  const Icon = kind === "image" ? Image : kind === "files" ? File : Type;
  return <div className="clipboard-entry-preview">
    <div className="clipboard-preview-heading"><Icon size={16} aria-hidden="true" />
      <strong>{t(kind === "image" ? "Image" : kind === "files" ? "File references" : "Text")}</strong>
    </div>
    {kind === "image" && current?.value ? <img className="clipboard-preview-image" src={current.value} alt={t("Clipboard image preview")} /> : null}
    {current?.error ? <span role="status">{t(kind === "image" ? "Image preview unavailable" : "Full text unavailable")}: {t(current.error)} <button onClick={() => setRetry((value) => value + 1)}>{t("Retry")}</button></span> : null}
    {(kind === "image" || kind === "text") && id !== undefined && native && !current ? <span role="status">{t(kind === "image" ? "Loading image preview…" : "Loading full text…")}</span> : null}
    {content ? <div className="clipboard-preview-content">{content}</div> : null}
    <div className="clipboard-preview-metadata">
      {entry.capturedAt ? <time dateTime={new Date(entry.capturedAt).toISOString()}>{new Date(entry.capturedAt).toLocaleString()}</time> : null}
      {kind === "image" ? <span>{entry.width ?? "?"} × {entry.height ?? "?"} · {entry.mimeType ?? t("Unknown image format")}</span> : null}
      {typeof entry.byteSize === "number" && Number.isFinite(entry.byteSize) ? <span>{t("{0} KB stored", { 0: (entry.byteSize / 1024).toFixed(1) })}</span> : null}
      {kind === "files" ? <span>{t("{0} file references. File contents are never stored.", { 0: entry.fileCount ?? 0 })}</span> : null}
      {kind === "files" && entry.available == null ? <span>{t("File availability is checked when you copy or paste.")}</span> : null}
      {kind === "files" && entry.available === false ? <span role="status">{t("A referenced file is missing or unavailable. Restore it before copying or pasting.")}</span> : null}
      {kind === "image" ? <span>{t("Copy and paste reuse the original image. Image display depends on the destination app.")}</span> : null}
    </div>
  </div>;
}
