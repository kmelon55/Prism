# Launcher search foundations

Root search places applications and launcher commands above file results, then ranks by match quality inside each group. Exact filenames remain below matching applications; forty application candidates can fill the visible result window. The broader file-search action stays with file results. Up to eight supplementary file matches appear; exact title/common-alias matches and explicit exact user aliases are exempt. A surviving selected file may occupy one additional supplementary slot so arriving results do not silently change the Enter target.

## Match contract

| Priority | Match |
| --- | --- |
| 8 | Exact user alias |
| 7 | Provider-recognized intent for this exact query |
| 6 | Exact title or common application alias |
| 5 | Title or common application alias prefix |
| 4 | User alias prefix |
| 3 | Title or common application alias subsequence, including Hangul initials |
| 2 | User alias subsequence |
| 1 | Subtitle, section, keyword, or native application path |

Scores reserve one million points per tier. Subsequence quality is bounded within that tier and launch frequency/recency adds at most 72 points. Favorites add a small within-tier bonus during search and lead the empty-query list. Boosts never turn nonmatches into matches. User alias prefix/subsequence behavior remains conservative; only an exact user alias deliberately outranks title and intent matches.

Normalization folds case, compatibility width, and combining accents, then recomposes Unicode. Composed and decomposed Korean input match identically. Korean leading consonants can match complete Hangul syllables: `ㅋㄹ` and `크ㄹ` find Chrome through `크롬`; `한ㄱ 메ㅁ` finds `한글 메모`. Full syllables match literally, so `하글` does not become a match for `한글`. Matching uses Unicode code points, including emoji, rather than UTF-16 offsets. This is initials matching, not keyboard-layout conversion or transliteration.

## Common app aliases and retrieval

`packages/command-core/src/application-aliases.json` is the single catalog consumed by both TypeScript and Rust. Add exact installed-name variants under `names` and alternate searchable names under `aliases`; keep app families distinct. Exact name lookup intentionally excludes helpers such as `Google Chrome Helper`. The catalog includes common browsers, editors, communication tools, and macOS utilities. It does not infer arbitrary app translations.

Rust loads this bundled catalog once and caches normalized aliases beside each installed application. Native search scores names, aliases, and paths before applying its candidate limit (40 for a nonempty launcher query, 24 for empty; native hard maximum 100). TypeScript maps those same aliases to `CommandItem.searchAliases`, ensuring reranking retains Korean candidates. App paths remain searchable metadata on both sides. User-defined aliases stay separate: the bounded alias provider resolves matching stable native IDs directly, so user aliases do not depend on native name retrieval.

## Incremental results and selection

Pass the full candidate set into `navigate` with `pendingProviderIds`. Navigation retains matches from pending providers, replaces completed-provider rows with new payloads, rejects stale generations, and ranks before its forty-row display cap. A surviving selected ID is retained through the cap, replacing the last visible row if needed. Selection is reset when the query changes; removed results are not resurrected. Root integration must not trim or apply the supplementary file quota before navigation has the selected identity.

## Validation and native boundary

- `pnpm --filter @prism/command-core test`
- `pnpm --filter @prism/command-core typecheck`
- `pnpm --filter @prism/desktop exec vitest run src/interaction/navigation.test.ts src/providers/native.test.ts`
- `pnpm --filter @prism/desktop typecheck`
- Coordinator-owned serialized Rust verification: `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml application_index::tests` and the project Cargo check.

Regression tests cover applications preceding an exact file among sixty app candidates, supplementary-file limits, late results and stable selection, explicit alias priority, Hangul initials, mixed input, Unicode normalization, canceled native requests, and native retrieval before the candidate limit. TypeScript provider tests mock IPC; Rust tests use an in-memory catalog. Neither proves the behavior of an already-running native application. Existing development servers and native apps are preserved.
