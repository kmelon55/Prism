# Backup and settings recovery foundations

This update extends the existing backup implementation; its version and coverage notes supersede the version 1 restrictions in `backup-recovery.md`.

## Backup format and library restore

Exports use `format: "prism-backup"`, `version: 2`, and the filename `prism-backup-v2.json`. Imports accept versions 1 and 2. Legacy snippet entries without `keyword` remain valid. Optional `keyword` is preserved through the canonical library validator and SQLite save routine. Duplicate normalized keyword mappings among additions or against the destination are rejected during review, before any mutation; existing entry IDs still win conflicts. Import never changes text expansion enablement or Accessibility consent.

`Categories.pathLinks` defaults to false, including native requests that omit it. Selecting it exports/imports `kind: "path"` entries separately from HTTP(S) quicklinks. These remain absolute path references in the local platform's path syntax. Review returns `pathReferences` with each ID, title, path, `existing`/`missing`/`unavailable` status, and whether an existing ID wins. Checking a target uses metadata only. Missing paths are preserved as references so users can repair them later. Status is a review-time observation, not a guarantee that the target remains available or a grant to read it. The code never imports roots, enumerates or reads target contents, opens a path, or grants file/AI access.

Review additionally returns `missingFavorites` so skipped library favorite targets can be identified. Appearance restore displays alias additions, existing command-ID conflicts, normalized-value collisions, and capacity skips individually. Existing aliases win and the merge is recomputed from the latest preferences at restore time.

Malformed JSON, unsupported newer versions, unsupported fields, invalid records, duplicate keyword mappings, storage limits, and stale reviews have distinct errors. Newer-version detection precedes decoding the older schema so a newer document reports the version incompatibility even when it has new required fields. All categories are validated, including unselected categories. Parse/review failures leave library and preferences unchanged. Apply remains one immediate SQLite transaction; failure rolls back every insertion. Preferences restore remains a separate explicit operation.

The native review remains bounded to one in-memory snapshot, expires after 10 minutes, checks the exact destination library baseline, and consumes its token before every apply attempt. Failed apply requires a new chooser review. The existing 20 MiB input bound, regular-file checks, Unix symlink rejection, exclusive export temporary files, owner-only Unix permissions, sync/rename publication, and failed-export preservation remain intact.

## Preference persistence API and App integration

`apps/desktop/src/backup/preferencesPersistence.ts` is a frontend-only helper with injected storage; it does not launch a native chooser or touch native preferences.

- `loadPreferences(storage, normalize, defaults)` returns `{ preferences, status, recovery, original }`. Status is `ok`, `missing`, `malformed`, or `unavailable`. It is read-only. Valid older partial preferences still normalize normally. Invalid present field types/ranges, invalid JSON, non-object roots, or oversized settings use temporary defaults without overwriting stored bytes. Invalid or newer snapshots are never offered as recovery sources.
- `persistPreferences(storage, next)` validates and persists the primary `prism:preferences` key before returning. It refuses to overwrite malformed existing settings. A successful primary write is followed by an allowlisted snapshot in `prism:preferences:last-known-good:v1`; `{ snapshotSaved: false }` means the primary succeeded but the snapshot could not be updated. Do not report that as a failed primary save or leave App state inconsistent with the successful primary write.
- `recoverPreferences(storage, current, review)` is an explicit action. It consumes the review on every attempt, requires both original primary bytes and snapshot bytes to remain unchanged, expires after 10 minutes, reparses the exact reviewed snapshot, merges only allowlisted fields, and persists before returning `{ preferences, snapshotSaved }`. Update App refs/state only after this returns. A failed attempt needs a new `loadPreferences` review. Writes to an individual localStorage key are atomic; cross-window compare-and-write across two keys is not a transaction, and simultaneous writes after the recheck are not locked.
- `restoreReviewedBackupPreferences(storage, current, incomingSafe, expectedOriginal)` handles explicit backup-file preference restore, including a malformed primary with no valid snapshot. Pass `original` from the retained load result; it rechecks those bytes, preserves them in the single-slot `prism:preferences:before-recovery:v1` key, rechecks, then writes only the merged safe preferences. Preservation failure aborts before replacing the primary. The returned preferences and snapshotSaved follow the same persistence ordering contract. An archive may have been written if a later primary write fails; primary settings remain unchanged on that failure.
- `PreferencesRecovery.tsx` accepts `review`, `onRecover`, and `onReviewAgain`. Mount when status is `malformed`; show recovery contents, preserve the corrupt primary until explicit recovery, refresh the load result on review-again, and remove the recovery UI after successful recovery. If no valid snapshot exists, it offers backup-file recovery guidance and a reread action, never an automatic reset.

Coordinator-owned App hookup must route primary preference writes (including initial persistence, language/window synchronization, and ordinary settings changes) through the helper, suppress writes while primary settings are malformed or unavailable, retain the recovery state instead of silently swallowing the read error, and account for `snapshotSaved` separately. Use `restoreReviewedBackupPreferences` for explicitly reviewed backup preference restore into malformed primary settings; the ordinary persistence guard deliberately refuses to discard corruption. No recovery code restores keys, histories, script directories, disabled-command state, hotkeys, roots, permission grants, or text expansion enablement from the snapshot. Current non-allowlisted in-memory fields are retained when explicitly recovering safe fields.

The safe snapshot contains exactly language, theme, reduceMotion, backgroundOpacity, backgroundBlur, showApplicationIcons, and commandAliases. Snapshots are unencrypted browser storage and are not a replacement for an exported backup or a native database recovery mechanism. Explicit recovery preserves the previous primary bytes in the single-slot `prism:preferences:before-recovery:v1` key before replacement. This archive may include malformed sensitive data and is never used as an automatic restore source; both snapshot and before-recovery storage remain local and unencrypted. No extra archive is written during ordinary reads or ordinary preference saves. Originals larger than 1 MiB are refused by the recovery-preservation step.

## Integration status and validation

Worker ownership: `apps/desktop/src-tauri/src/library_backup.rs`, `apps/desktop/src/backup/**`, and this document. No edits to App, shared translations, library schema, lib registration, or Cargo manifest were made by this worker.

The coordinator has implemented `Entry.keyword: Option<String>`, the nullable SQLite column, canonical keyword validation, and `normalized_keyword` in `library.rs`. Backup calls the existing parent `save` inside its transaction. The coordinator added the snippet registry refresh after the library lock is released in `backup_apply_import`, verified in the current source. Refresh must retain the user's existing expansion enablement and consent state.

Worker validation:

```sh
pnpm --filter @prism/desktop exec vitest run src/backup
# 4 files, 26 tests passed
pnpm --filter @prism/desktop exec tsc -b --pretty false
# passed on final rerun after coordinator corrected the readPreferences callers
```

Rust file was formatted with `rustfmt --edition 2021`. Coordinator owns native test execution to avoid concurrent Cargo builds:

```sh
cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml library::backup::tests --lib
```

New Rust tests cover optional existing/missing path references without root restoration, keyword round-trip and review-time conflicts without writes, and distinct malformed/newer/unsupported errors. Existing tests cover atomic rollback/fresh retry, ID conflicts, stale/replaced/expired/single-use reviews, capacity, unsafe unselected categories, preference allowlisting, and bounded atomic export/read behavior. Frontend additions cover alias conflict reasons, opt-in paths and missing favorite identities, malformed settings preservation, unsafe/newer snapshot rejection, storage failure, stale/expired/consumed recovery reviews, safe-field restoration, and explicit recovery UI retry behavior.

All tests use mocked native IPC, disposable path fixtures, in-memory databases, or injected/local test storage. No native chooser interaction against real user files was tested. No development server or native app was started, restarted, or stopped. No Git mutation, worktree, network provider run, deployment, or publication was performed.

## Shared translation additions

Coordinator owns `apps/desktop/src/locales/messages.json`; add these English/Korean pairs using the existing format:

```json
[
  ["Path references", "경로 참조"],
  ["Path references are optional. They restore saved paths only; file search roots and AI access are never granted. Missing targets remain unavailable until repaired.", "경로 참조는 선택 항목입니다. 저장된 경로만 복원하며 파일 검색 폴더나 AI 접근 권한을 부여하지 않습니다. 대상이 없으면 경로를 수정해야 사용할 수 있습니다."],
  ["Review path targets", "경로 대상 검토"],
  ["Target exists", "대상 있음"],
  ["Target missing", "대상 없음"],
  ["Target could not be checked", "대상을 확인하지 못함"],
  ["Existing item kept", "기존 항목 유지"],
  ["Favorites skipped because their library targets are missing", "보관함 대상이 없어 건너뛴 즐겨찾기"],
  ["Review alias changes", "별칭 변경 검토"],
  ["Add alias", "별칭 추가"],
  ["Existing command alias kept", "기존 명령 별칭 유지"],
  ["Alias already used; skipped", "이미 사용 중인 별칭으로 건너뜀"],
  ["Alias limit reached; skipped", "별칭 한도에 도달하여 건너뜀"],
  ["This backup contains invalid data. Nothing was imported.", "백업에 올바르지 않은 데이터가 있습니다. 아무 항목도 가져오지 않았습니다."],
  ["This backup is malformed JSON. Nothing was imported.", "백업 JSON 형식이 손상되었습니다. 아무 항목도 가져오지 않았습니다."],
  ["This backup uses a newer unsupported version. Update Prism before importing.", "지원하지 않는 최신 버전의 백업입니다. Prism을 업데이트한 후 가져오세요."],
  ["This backup contains unsupported fields or data. Nothing was imported.", "백업에 지원하지 않는 필드나 데이터가 있습니다. 아무 항목도 가져오지 않았습니다."],
  ["A snippet keyword conflicts with another snippet. Nothing was imported.", "스니펫 키워드가 다른 스니펫과 충돌합니다. 아무 항목도 가져오지 않았습니다."],
  ["Local settings are malformed. Review recovery before saving changes.", "로컬 설정이 손상되었습니다. 변경 사항을 저장하기 전에 복구 내용을 검토하세요."],
  ["Settings changed or recovery expired. Review recovery again.", "설정이 변경되었거나 복구 검토가 만료되었습니다. 복구 내용을 다시 검토하세요."],
  ["Recover local settings", "로컬 설정 복구"],
  ["Local settings could not be read", "로컬 설정을 읽지 못했습니다"],
  ["Temporary defaults are in use. Your stored settings have been preserved. Recovery restores only appearance, language, and aliases.", "임시 기본 설정을 사용하고 있습니다. 저장된 설정은 그대로 보존했습니다. 복구는 화면 설정, 언어, 별칭만 복원합니다."],
  ["Review last-known-good settings", "마지막 정상 설정 검토"],
  ["Recover last-known-good settings", "마지막 정상 설정 복구"],
  ["No valid settings snapshot is available. You can review a backup file to restore safe preferences.", "사용할 수 있는 정상 설정 사본이 없습니다. 백업 파일을 검토하여 안전한 설정을 복원할 수 있습니다."],
  ["Review recovery again", "복구 다시 검토"],
  ["Stored settings are too large to preserve before recovery.", "저장된 설정이 너무 커서 복구 전에 보존할 수 없습니다."]
]
```
