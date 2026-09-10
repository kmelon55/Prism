# Local backup and recovery

Prism exports version 1 JSON files through a native save dialog and imports only a file selected through a native open dialog. Settings → Backup & Restore offers snippets, quicklinks, favorites, and an optional safe preferences category. Import always previews the selected library counts before adding anything. Existing IDs win conflicts; import never deletes or replaces a library record. Missing library favorite targets are skipped. Existing favorite order is preserved, with new favorites appended.

## Storage and authority contract

The file has `format: "prism-backup"`, `version: 1`, `entries`, `favorites`, and nullable `preferences`. Only snippet and HTTP(S) quicklink entries are supported. Unknown fields, unknown versions, duplicate IDs, invalid links/records, unsafe preferences, and files over 20 MiB are rejected before any mutation, including malformed unselected categories. Library limits remain 1,000 entries, 16 MiB of entry content, 128 KiB per entry, and 50 favorites. Exporting favorites alone retains their IDs; import resolves library favorites against the merged destination library and skips missing targets.

A native review stores the validated additions plus the exact library baseline in memory. The renderer receives an opaque single-use token, counts, and the allowlisted preferences snapshot, never disk path authority. Apply consumes the token before any failure path, acquires the existing library lock, rechecks the complete baseline inside an immediate SQLite transaction, and commits all library additions together. A library change or a review older than 10 minutes requires a new review. A new successful review invalidates the previous token. Failed apply retries reopen the chooser and require explicit confirmation again; they never replay the old token.

The chooser reader bounds metadata and actual bytes, requires a regular file, and rejects symlinks on Unix without following them. Export creates an exclusive sibling temporary file with owner-only Unix permissions, writes and syncs it, then renames it over the chosen destination. Failed writes or renames remove the temporary file and preserve the prior destination. Platforms that cannot rename over an existing destination report failure and preserve it. This does not claim directory-entry durability through sudden power loss. Backups are ordinary unencrypted local files, and snippets can contain sensitive user content.

## Safe preferences are a separate explicit restore

The exact allowlist is `language`, `theme`, `reduceMotion`, `backgroundOpacity` (88–100), `backgroundBlur` (0–60), `showApplicationIcons`, and `commandAliases` (at most 1,000 entries with valid IDs and at most 80 UTF-16 code units per alias, matching existing settings). Both native import and the frontend reject additional fields. Prototype-sensitive alias IDs are rejected. Export picks only this allowlist from current settings.

The preview shows every appearance/language setting and alias additions/conflicts. The separate **Restore appearance, language, and aliases** action replaces only those appearance/language fields and conservatively merges aliases into the latest preferences. Existing alias IDs, normalized alias-value collisions, and aliases above capacity are kept/skipped. Existing disabled commands and all other preferences stay intact. No keys, clipboard history, AI history, permission grants, search roots, path entries, script directories, shortcuts, or command enablement are restored; no execution or hotkey registration is triggered by backup code.

Library import is atomic in SQLite. Preferences use the application's existing localStorage persistence and are explicitly independent: a failed preferences restore leaves a successful library import intact and exposes only a preferences retry. The App integration persists localStorage before changing its preferences ref/state. Native preference notification remains best effort; this is not an atomic transaction across SQLite, localStorage, and every application window.

## Integration hooks

The library owner adds the child module, providing its existing lock, database, validation, and change event helpers:

```rust
#[path = "library_backup.rs"]
pub mod backup;
```

The coordinator registers state and commands in `lib.rs`:

```rust
.manage(library::backup::BackupState::default())
// Inside tauri::generate_handler!:
library::backup::backup_export,
library::backup::backup_preview_import,
library::backup::backup_apply_import,
```

The coordinator mounts the section in `App.tsx`:

```tsx
import { BackupSettings } from "./backup/BackupSettings";
import { mergeSafePreferences } from "./backup/backup";

backupDetails={
  <BackupSettings
    nativeRuntime={nativeRuntime}
    preferences={preferences}
    onRestorePreferences={(safe) =>
      updatePreferences(mergeSafePreferences(preferencesRef.current, safe))
    }
  />
}
```

`onRestorePreferences` must throw/reject if persistence fails and must not update in-memory settings first. The native `prism:library-changed` event refreshes library consumers after a committed import. No additional App import callback is needed.

## Changed files and validation

Worker-owned files:

- `apps/desktop/src-tauri/src/library_backup.rs`
- `apps/desktop/src/backup/backup.ts`
- `apps/desktop/src/backup/BackupSettings.tsx`
- `apps/desktop/src/backup/backup.css`
- `apps/desktop/src/backup/backup.test.ts`
- `apps/desktop/src/backup/BackupSettings.test.tsx`
- `apps/desktop/src/settings/SettingsView.tsx`
- `apps/desktop/src/settings/settingsNavigation.ts`
- `apps/desktop/src/settings/SettingsView.test.tsx`
- `docs/backup-recovery.md`

Focused frontend command: `pnpm --filter @prism/desktop exec vitest run src/backup/backup.test.ts src/backup/BackupSettings.test.tsx src/settings/SettingsView.test.tsx`. Final focused result: 22 tests passed. Desktop `tsc -b --pretty false` passed. Native tests are coordinator-owned to avoid concurrent Cargo runs: `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml library::backup::tests --lib`. The coordinator reported all 12 native tests passed before the final favorites-export adjustment, Korean alias length alignment, and additional file-bound assertions; rerun after those changes.

Tests cover conservative conflicts, selected-category behavior, malformed/future/oversized/duplicate/unsafe files, capacity rejection, transaction rollback after an injected write failure and successful fresh retry, changed-library rejection, expired/single-use/replaced tokens, safe preferences allowlisting, alias collision preservation, export failure cleanup, special-file rejection, UI review-before-apply, chooser cancellation, category invalidation, failed-import fresh review, preferences-only retry, export-only retry, and duplicate-click suppression. Fixtures use in-memory databases, disposable directories, and mocked native IPC; no real user library or preferences are imported by tests.

Coordinator-confirmed integration includes App mounting, native state/command registration, persistence ordering, and all 44 translation pairs. The coordinator reported 145 native tests passed with 3 intentionally ignored before the last Korean-alias assertion update. Remaining verification: the final native backup rerun, final full frontend integration suite, actual native chooser/export/import interaction, and multiwindow notification behavior. No development server or running app was started, stopped, or restarted. No Cargo command was run by this worker, no paid calls were made, and no commit or publication occurred.

## Translation additions for the coordinator

Append missing pairs to `apps/desktop/src/locales/messages.json`; the worker deliberately does not edit that shared file.

```json
[
  ["Aliases in backup", "백업의 별칭"],
  ["Backup & Restore", "백업 및 복원"],
  ["Backup and restore are available in the desktop app.", "백업과 복원은 데스크톱 앱에서 사용할 수 있습니다."],
  ["Backup categories", "백업 항목"],
  ["Backup files are not encrypted. Keep them somewhere private. Maximum file size: 20 MB.", "백업 파일은 암호화되지 않습니다. 안전한 곳에 보관하세요. 최대 파일 크기는 20 MB입니다."],
  ["Backup files must be 20 MB or smaller.", "백업 파일은 20 MB 이하여야 합니다."],
  ["Backup saved.", "백업을 저장했습니다."],
  ["Category", "항목"],
  ["Choose backup to review", "백업 파일 선택 및 검토"],
  ["Choose what to export or import. Existing library items win conflicts.", "내보내거나 가져올 항목을 선택하세요. 충돌하면 기존 보관함 항목을 유지합니다."],
  ["Close review", "검토 닫기"],
  ["Conflicts kept", "충돌 시 유지"],
  ["Export and review local backups", "로컬 백업 내보내기 및 검토"],
  ["Export backup", "백업 내보내기"],
  ["Import new library items", "새 보관함 항목 가져오기"],
  ["In file", "파일 내 항목"],
  ["Library restored", "보관함 복원 완료"],
  ["Library restored. Existing items were kept.", "보관함을 복원했습니다. 기존 항목은 유지했습니다."],
  ["Local backup", "로컬 백업"],
  ["No new library items to import.", "가져올 새 보관함 항목이 없습니다."],
  ["Only new library items will be added. Missing library favorites are skipped. Review expires after 10 minutes or a library change.", "새 보관함 항목만 추가합니다. 대상이 없는 보관함 즐겨찾기는 건너뜁니다. 10분이 지나거나 보관함이 변경되면 다시 검토해야 합니다."],
  ["Restore appearance, language, and aliases", "화면 설정, 언어 및 별칭 복원"],
  ["Restore safe preferences separately", "안전한 설정 별도 복원"],
  ["Retry export", "내보내기 다시 시도"],
  ["Retry preferences restore", "설정 복원 다시 시도"],
  ["Review backup", "백업 검토"],
  ["Review file again", "파일 다시 검토"],
  ["Safe preferences", "안전한 설정"],
  ["Safe preferences include appearance, language, and aliases. Keys, histories, permissions, script folders, and hotkeys are excluded.", "안전한 설정에는 화면 설정, 언어, 별칭이 포함됩니다. 키, 기록, 권한, 스크립트 폴더, 단축키는 제외합니다."],
  ["Safe preferences restored", "안전한 설정 복원 완료"],
  ["Safe preferences restored.", "안전한 설정을 복원했습니다."],
  ["Select at least one backup category.", "백업 항목을 하나 이상 선택하세요."],
  ["Selected library categories", "선택한 보관함 항목"],
  ["Skipped", "건너뜀"],
  ["The backup could not be saved. The existing file was preserved.", "백업을 저장하지 못했습니다. 기존 파일은 유지했습니다."],
  ["The backup file could not be read.", "백업 파일을 읽지 못했습니다."],
  ["The backup review expired or the library changed. Review the file again.", "백업 검토가 만료되었거나 보관함이 변경되었습니다. 파일을 다시 검토하세요."],
  ["The library could not be restored. Review the file and try again.", "보관함을 복원하지 못했습니다. 파일을 검토하고 다시 시도하세요."],
  ["The merged library exceeds its storage limit.", "항목을 합치면 보관함의 저장 한도를 초과합니다."],
  ["This backup contains no safe preferences.", "이 백업에는 안전한 설정이 없습니다."],
  ["This backup is invalid or unsupported.", "올바르지 않거나 지원하지 않는 백업입니다."],
  ["This replaces appearance and language. Existing aliases and alias conflicts are kept. Library import is a separate operation.", "화면 설정과 언어를 변경합니다. 기존 별칭과 충돌하는 별칭은 유지합니다. 보관함 가져오기는 별도 작업입니다."],
  ["Working…", "처리 중…"],
  ["{0} aliases to add · {1} conflicts or capacity skips", "별칭 {0}개 추가 · 충돌 또는 용량 제한으로 {1}개 건너뜀"]
]
```
