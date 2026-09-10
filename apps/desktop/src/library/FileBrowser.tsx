import "./file-search.css";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Copy, FolderOpen, Plus, Trash2 } from "lucide-react";
import { fileIconName, fileIcons } from "../fileIcons";
import { t, useLocale } from "../i18n";
import { isCompositionKey } from "../interaction/usePaletteKeyboard";
import { type FileRoot, type FileType } from "../providers/library";
import { useFileBrowser } from "./useFileBrowser";

export interface FileBrowserProps {
  nativeRuntime: boolean;
  initialIncludeSystem?: boolean;
  query: string;
  offset: number;
  revision: number;
  roots: FileRoot[];
  busy: boolean;
  onOffset(offset: number): void;
  onAction(id: string, action: "open" | "reveal" | "copy"): void;
  onRemoveRoot(id: string): void;
  onAddRoot?(): void;
}
const filters: [FileType, string][] = [
  ["all", "모든 파일"],
  ["folder", "폴더"],
  ["text", "텍스트"],
  ["image", "이미지"],
  ["document", "문서"],
];

export function FileBrowser(props: FileBrowserProps) {
  const locale = useLocale();
  const [fileType, setFileType] = useState<FileType>("all");
  const list = useRef<HTMLDivElement>(null);
  const scopeKey = JSON.stringify([props.query, fileType]);
  const [broaderScope, setBroaderScope] = useState<string | null>(
    () => props.initialIncludeSystem ? scopeKey : null,
  );
  const includeSystem = broaderScope === scopeKey;
  useEffect(() => {
    if (broaderScope !== null && broaderScope !== scopeKey) setBroaderScope(null);
  }, [broaderScope, scopeKey]);
  const browser = useFileBrowser({
    enabled: props.nativeRuntime,
    query: props.query,
    offset: props.offset,
    revision: props.revision,
    rootsKey: JSON.stringify(props.roots),
    fileType,
    includeSystem,
  });
  const { files, selected, preview, current } = browser;
  const canAct = current && !props.busy && props.nativeRuntime;

  useEffect(() => {
    list.current
      ?.querySelector<HTMLElement>('[aria-selected="true"]')
      ?.scrollIntoView?.({ block: "nearest" });
  }, [selected?.id]);

  function keyDown(event: KeyboardEvent) {
    if (
      isCompositionKey(event.nativeEvent) ||
      event.altKey ||
      event.metaKey ||
      event.ctrlKey
    )
      return;
    const index = files.items.findIndex((file) => file.id === selected?.id);
    let next = index;
    if (event.key === "ArrowDown")
      next = Math.min(files.items.length - 1, index + 1);
    else if (event.key === "ArrowUp") next = Math.max(0, index - 1);
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = files.items.length - 1;
    else if (event.key === "Enter" && selected && canAct) {
      event.preventDefault();
      if (!event.repeat) props.onAction(selected.id, "open");
      return;
    } else return;
    event.preventDefault();
    if (files.items[next]) browser.setSelectedId(files.items[next].id);
  }

  return (
    <>
      <details className="file-search-folders">
        <summary>{t("추가 검색 폴더")}{props.roots.length ? ` (${props.roots.length})` : ""}</summary>
        <p>{t("홈 폴더를 자동으로 검색합니다. 필요한 폴더만 추가하세요.")}</p>
        <div className="library-roots">
          {props.roots.map((root) => (
            <div key={root.id}>
              <FolderOpen size={14} />
              <span title={root.path}>{root.path}</span>
              <button disabled={props.busy} aria-label={t("{0} 검색 제외", { 0: root.path })} onClick={() => props.onRemoveRoot(root.id)}><Trash2 size={13} /></button>
            </div>
          ))}
        </div>
        {props.onAddRoot && <button disabled={props.busy || !props.nativeRuntime} onClick={props.onAddRoot}><Plus size={14} />{t("폴더 추가")}</button>}
      </details>
      <div className="library-file-filters">
        <label>
          {t("파일 종류")}
          <select
            aria-label={t("파일 종류")}
            value={fileType}
            onChange={(event) => {
              setFileType(event.target.value as FileType);
              props.onOffset(0);
            }}
          >
            {filters.map(([value, label]) => (
              <option key={value} value={value}>
                {t(label)}
              </option>
            ))}
          </select>
        </label>
        {props.query.trim() && (
          <button
            className="file-search-broader"
            disabled={!props.nativeRuntime || props.busy}
            aria-pressed={includeSystem}
            onClick={() => {
              setBroaderScope(includeSystem ? null : scopeKey);
              props.onOffset(0);
            }}
          >
            {t(includeSystem ? "인덱스에서만 검색" : "더 넓게 검색")}
          </button>
        )}
      </div>
      {includeSystem && <p className="file-search-scope">{t("시스템 검색 결과를 포함합니다. 일부 파일은 표시되지 않을 수 있습니다.")}</p>}
      {browser.loading && <p role="status">{t("파일을 찾고 있습니다…")}</p>}
      {files.indexing && <p role="status">{t("파일 목록을 갱신하고 있습니다. 검색 결과가 추가될 수 있습니다.")}</p>}
      {(browser.error || files.error) && <p role="alert">{t(browser.error || files.error || "")}</p>}
      <div className="library-file-browser">
        <div
          ref={list}
          className="library-file-list"
          role="listbox"
          aria-label={t("파일 검색 결과")}
          aria-busy={browser.loading}
          tabIndex={0}
          aria-activedescendant={
            selected ? `library-file-${selected.id}` : undefined
          }
          onKeyDown={keyDown}
        >
          {files.items.map((file) => {
            const Icon = fileIcons[fileIconName(file.name, file.isDirectory)];
            return (
              <div
                id={`library-file-${file.id}`}
                key={file.id}
                role="option"
                aria-selected={file.id === selected?.id}
                className="library-row"
                onClick={() => {
                  browser.setSelectedId(file.id);
                  list.current?.focus();
                }}
                onDoubleClick={() => {
                  if (canAct) props.onAction(file.id, "open");
                }}
              >
                <Icon size={18} aria-hidden="true" />
                <span className="library-row-main">
                  <strong>{file.name}</strong>
                  <small>{file.path}</small>
                </span>
              </div>
            );
          })}
          {!files.total && !browser.loading && !files.indexing && !files.error && !browser.error && (
            <p>{t("일치하는 파일이 없습니다.")}</p>
          )}
        </div>
        {selected && (
          <aside
            className="library-file-preview"
            aria-label={t("파일 미리보기")}
            aria-busy={browser.previewLoading}
          >
            <strong>{selected.name}</strong>
            {browser.previewLoading && (
              <p role="status">{t("미리보기를 불러오는 중…")}</p>
            )}
            {browser.previewError && (
              <p role="alert">{t(browser.previewError)}</p>
            )}
            {preview && (
              <>
                <dl className="library-file-metadata">
                  <dt>{t("경로")}</dt>
                  <dd>{preview.path}</dd>
                  <dt>{t("종류")}</dt>
                  <dd>
                    {preview.isDirectory
                      ? t("폴더")
                      : preview.extension || t("파일")}
                  </dd>
                  {!preview.isDirectory && (
                    <>
                      <dt>{t("크기")}</dt>
                      <dd>
                        {new Intl.NumberFormat(locale).format(preview.size)} B
                      </dd>
                    </>
                  )}
                  {preview.modifiedAt !== null && (
                    <>
                      <dt>{t("수정한 날짜")}</dt>
                      <dd>
                        {new Date(preview.modifiedAt).toLocaleString(locale)}
                      </dd>
                    </>
                  )}
                </dl>
                {preview.kind === "text" && (
                  <pre className="library-file-text">{preview.text}</pre>
                )}
                {preview.kind === "image" && preview.imageDataUrl && (
                  <img
                    className="library-file-image"
                    src={preview.imageDataUrl}
                    alt={selected.name}
                  />
                )}
                {preview.kind === "unsupported" && (
                  <p>{t("이 파일은 미리보기를 지원하지 않습니다.")}</p>
                )}
                {preview.truncated && <p>{t("파일의 일부만 표시합니다.")}</p>}
              </>
            )}
            <div className="library-buttons">
              <button
                disabled={!canAct}
                onClick={() => props.onAction(selected.id, "open")}
              >
                {t("열기")}
              </button>
              <button
                disabled={!canAct}
                aria-label={t("{0} Finder에서 보기", { 0: selected.name })}
                onClick={() => props.onAction(selected.id, "reveal")}
              >
                <FolderOpen size={14} />
              </button>
              <button
                disabled={!canAct}
                aria-label={t("{0} 경로 복사", { 0: selected.name })}
                onClick={() => props.onAction(selected.id, "copy")}
              >
                <Copy size={14} />
              </button>
            </div>
          </aside>
        )}
      </div>
      <div className="library-buttons">
        <button
          disabled={!props.offset || browser.loading}
          onClick={() => props.onOffset(Math.max(0, props.offset - 40))}
        >
          {t("이전")}
        </button>
        <span>
          {t("{0} items", { 0: files.total })}
          {files.limited
            ? t(" · 일부 폴더를 읽지 못했거나 목록 한도에 도달했습니다")
            : ""}
        </span>
        <button
          disabled={props.offset + 40 >= files.total || browser.loading}
          onClick={() => props.onOffset(props.offset + 40)}
        >
          {t("다음")}
        </button>
      </div>
    </>
  );
}
