import type { RefObject } from "react";
import { invoke } from "@tauri-apps/api/core";
import { t } from "../i18n";
import type { LibraryEntry } from "../providers/library";
import { snippetCopy, validSnippetKeyword } from "../snippets/copy";

export function LibraryEntryEditor({
  editor,
  setEditor,
  busy,
  nativeRuntime,
  input,
  leave,
  save,
  discard,
  setDiscard,
  work,
}: {
  editor: LibraryEntry;
  setEditor(entry: LibraryEntry | null): void;
  busy: boolean;
  nativeRuntime: boolean;
  input: RefObject<HTMLInputElement | null>;
  leave(): void;
  save(): Promise<void>;
  discard: boolean;
  setDiscard(value: boolean): void;
  work(fn: () => Promise<unknown>, message?: string): Promise<void>;
}) {
  const keywordValid = editor.kind !== "snippet" || validSnippetKeyword(editor.keyword);
  return (
    <form
      className="library-editor"
      onSubmit={(e) => {
        e.preventDefault();
        if (keywordValid) void save();
      }}
    >
      <label>
        {t("이름")}
        <input
          ref={input}
          aria-label={t("항목 이름")}
          value={editor.title}
          maxLength={100}
          disabled={busy}
          onChange={(e) => setEditor({ ...editor, title: e.target.value })}
        />
      </label>
      {editor.kind !== "snippet" && (
        <label>
          {t("종류")}
          <select
            aria-label={t("링크 종류")}
            value={editor.kind}
            disabled={busy}
            onChange={(e) =>
              setEditor({
                ...editor,
                kind: e.target.value as "link" | "path",
                value: "",
              })
            }
          >
            <option value="link">{t("웹 링크")}</option>
            <option value="path">{t("파일·폴더")}</option>
          </select>
        </label>
      )}
      <label>
        {editor.kind === "snippet"
          ? t("내용")
          : editor.kind === "path"
            ? t("경로")
            : t("주소")}
        {editor.kind === "snippet" ? (
          <textarea
            aria-label={t("스니펫 내용")}
            value={editor.value}
            disabled={busy}
            maxLength={128000}
            onChange={(e) => setEditor({ ...editor, value: e.target.value })}
          />
        ) : (
          <input
            aria-label={t("링크 주소")}
            placeholder={editor.kind === "link" ? "https://…" : "/Users/…"}
            value={editor.value}
            disabled={busy}
            onChange={(e) => setEditor({ ...editor, value: e.target.value })}
          />
        )}
      </label>
      {editor.kind === "snippet" && (
        <label>
          {snippetCopy("keyword")}
          <input
            aria-label={snippetCopy("keyword")}
            aria-describedby="snippet-keyword-hint"
            aria-invalid={!keywordValid}
            value={editor.keyword ?? ""}
            placeholder=";email"
            maxLength={48}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            disabled={busy}
            onChange={(event) => setEditor({ ...editor, keyword: event.target.value || undefined })}
          />
          <span id="snippet-keyword-hint" className="library-template-hint">
            {snippetCopy(keywordValid ? "keywordHint" : "invalidKeyword")}
          </span>
        </label>
      )}
      {editor.kind === "link" && (
        <p className="library-template-hint">
          {t("URL 쿼리에 {query}를 넣어 검색어를 입력받으세요.")}
        </p>
      )}
      {editor.kind === "snippet" && (
        <p className="library-template-hint">
          {t("{date}, {time}, {clipboard}로 날짜, 시간, 클립보드를 넣으세요.")}
        </p>
      )}
      {editor.kind === "path" && (
        <div className="library-buttons">
          {[false, true].map((folder) => (
            <button
              type="button"
              key={String(folder)}
              disabled={busy || !nativeRuntime}
              onClick={() =>
                void work(async () => {
                  const path = await invoke<string | null>(
                    "library_choose_path",
                    { folder },
                  );
                  if (path) setEditor({ ...editor, value: path });
                })
              }
            >
              {folder ? t("폴더 선택") : t("파일 선택")}
            </button>
          ))}
        </div>
      )}
      <div className="library-buttons">
        <button type="button" onClick={leave} disabled={busy}>
          {t("취소")}
        </button>
        <button
          type="submit"
          disabled={
            busy || !nativeRuntime || !editor.title.trim() || !editor.value || !keywordValid
          }
        >
          {t("저장")}
        </button>
      </div>
      {discard && (
        <div className="library-confirm" role="alert">
          <span>{t("변경 내용을 저장할까요?")}</span>
          <button type="button" onClick={() => void save()} disabled={busy || !keywordValid}>
            {t("저장")}
          </button>
          <button
            type="button"
            onClick={() => {
              setEditor(null);
              setDiscard(false);
            }}
            disabled={busy}
          >
            {t("변경 버리기")}
          </button>
          <button type="button" onClick={() => setDiscard(false)}>
            {t("계속 편집")}
          </button>
        </div>
      )}
    </form>
  );
}
