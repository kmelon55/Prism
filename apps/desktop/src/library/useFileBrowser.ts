import { useEffect, useState } from "react";
import {
  previewFile,
  searchFiles,
  watchFileIndex,
  type FilePreview,
  type FileResults,
  type FileType,
} from "../providers/library";
import { t } from "../i18n";

export const libraryError = (error: unknown) =>
  typeof error === "string" ? error : t("작업을 완료하지 못했습니다.");
const emptyFiles: FileResults = { items: [], total: 0, limited: false };

/** Keep the last successful page visible while new work is pending. */
export function useFileBrowser({
  enabled,
  query,
  offset,
  revision,
  rootsKey,
  fileType,
  includeSystem = false,
}: {
  enabled: boolean;
  query: string;
  offset: number;
  revision: number;
  rootsKey: string;
  fileType: FileType;
  includeSystem?: boolean;
}) {
  const [files, setFiles] = useState(emptyFiles);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [snapshot, setSnapshot] = useState("");
  const [indexRevision, setIndexRevision] = useState(0);
  useEffect(() => {
    if (!enabled) return;
    let active = true;
    let focused = true;
    const refresh = () => {
      if (active && focused && document.visibilityState !== "hidden")
        setIndexRevision((v) => v + 1);
    };
    const focus = () => { focused = true; refresh(); };
    const blur = () => { focused = false; };
    const unlisten = watchFileIndex(refresh).then((stop) => {
      // Catch a publication that raced the asynchronous native subscription.
      refresh();
      return stop;
    }).catch((reason) => {
      if (active) setError(libraryError(reason));
      return () => {};
    });
    // Native events publish completed batches. Focus catches events missed while
    // hidden; idle windows do not poll or trigger periodic disk scans.
    window.addEventListener("focus", focus);
    window.addEventListener("blur", blur);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      active = false;
      window.removeEventListener("focus", focus);
      window.removeEventListener("blur", blur);
      document.removeEventListener("visibilitychange", refresh);
      void unlisten.then((stop) => stop());
    };
  }, [enabled]);
  const requestKey = JSON.stringify([
    query,
    offset,
    revision,
    rootsKey,
    fileType,
    indexRevision,
    includeSystem,
  ]);
  const current = snapshot === requestKey;
  useEffect(() => {
    setFiles(emptyFiles);
    setSelectedId(null);
    setSnapshot("");
  }, [rootsKey]);

  useEffect(() => {
    if (!enabled) return;
    let active = true;
    setLoading(true);
    setError("");
    const timer = window.setTimeout(() => {
      void searchFiles(query, offset, 40, fileType, includeSystem)
        .then((next) => {
          if (!active) return;
          setFiles(next);
          setSelectedId((id) =>
            next.items.some((file) => file.id === id)
              ? id
              : (next.items[0]?.id ?? null),
          );
          setSnapshot(requestKey);
        })
        .catch((reason) => {
          if (active) setError(libraryError(reason));
        })
        .finally(() => {
          if (active) setLoading(false);
        });
    }, 0);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [enabled, requestKey, query, offset, fileType, includeSystem]);

  const selected = files.items.find((file) => file.id === selectedId) ?? null;
  const [preview, setPreview] = useState<FilePreview | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState("");
  useEffect(() => {
    setPreview(null);
    setPreviewError("");
    if (!enabled || !selectedId || !current) {
      setPreviewLoading(false);
      return;
    }
    let active = true;
    setPreviewLoading(true);
    void previewFile(selectedId)
      .then((value) => {
        if (active) setPreview(value);
      })
      .catch((reason) => {
        if (active) setPreviewError(libraryError(reason));
      })
      .finally(() => {
        if (active) setPreviewLoading(false);
      });
    return () => {
      active = false;
    };
  }, [enabled, selectedId, current, snapshot]);

  return {
    files,
    loading,
    error,
    selected,
    setSelectedId,
    current,
    preview: preview?.id === selectedId && current ? preview : null,
    previewLoading,
    previewError,
  };
}
