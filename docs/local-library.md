# Local library and clipboard actions

Search **Quicklinks / 링크** or **Snippets / 스니펫** to open that feature directly, or **Library / 보관함** to manage them. Its links, snippets, files and favorites tabs share a
compact search/list editor. Saved entries also appear directly in launcher search. Select a row to
edit, use its explicit open/copy control to execute, and confirm deletion. Closing an unsaved editor
asks whether to save, discard or keep editing; a failed save preserves the input.

Links accept HTTP(S) without embedded credentials or an absolute file/folder path. File and folder
buttons use the native picker. Snippets store literal text and expose copy/paste in launcher actions.
Explicit previews expand `{date}`, `{time}` and `{clipboard}`; quicklinks can preview `{query}`. Global automatic abbreviation expansion remains unimplemented.

The command action menu can add/remove favorites for built-in commands, installed applications and
saved entries. Library can reorder them. Favorites lead the empty query; a small search boost never
outweighs an exact match. Removed applications and disabled commands do not become runnable because
they were favorited. Settings shortcuts and aliases remain independent.

## Storage and file search

`library-v1.sqlite3` in the native app data directory stores entries, selected roots and favorite order.
It is local plaintext with Unix mode 0600, not encrypted credential storage. It holds at most 1,000
entries, 16 MiB of entry content, 128 KiB per entry, 50 favorites and 12 search roots. Native mutations
serialize writes; entry deletion and removal from favorites share a transaction.

File search is available from the root palette and the direct Files view. An in-memory filename index
covers the home folder automatically and any additional folders selected through the native chooser.
Cached results return without the previous root debounce or waiting for Spotlight. A bounded macOS
Spotlight fallback runs on indexed misses. Matching normalizes Korean filenames and remains an O(N)
scan of pre-normalized rows; results are capped and paginated without cloning or sorting all matches.

Refresh reuses unchanged directories and rejects stale generations after root changes. Files refreshes
every five seconds while focused and visible, and on focus; there is no always-on filesystem event
watcher or persistent disk snapshot. Scans bound depth, entries and cooperative elapsed time, skip
hidden/dependency/build paths and symlinks, and publish partial/indexing states. Explicit refresh
bypasses directory caches. Actions revalidate issued IDs, current roots and canonical paths; root
removal never deletes files. Search neither reads file contents nor grants AI permission.
See [file-search details and limits](file-search-improvements.md).

Versioned backup/recovery supports snippets, HTTP(S) quicklinks and favorites, with a reviewed
conservative import and a separate allowlisted preference restore. See [backup recovery](backup-recovery.md).

## Clipboard and paste

Clipboard history is opt-in, text-only and persisted locally with retention and pins. Copy keeps Prism open. Individual deletion
removes only the selected history record. Paste and snippet paste require macOS Accessibility access,
a live captured application, and the same focused window as when Prism opened. Prism copies the
text, activates that target and rechecks it before sending Command+V. A target change aborts the
injection and restores Prism; copy remains available. Clipboard contents may already have changed
when a late activation error occurs, which the error explains. Other platforms expose Copy fallback.

## Verification

React tests use mocked IPC for save failure, unsaved-editor recovery, deletion, stale file results,
pinning/restoration and clipboard copy/delete. Rust tests use isolated SQLite and temporary files for
record validation, roundtrip/update, filename indexing and revoked-root/traversal checks. Browser
fixtures on the existing Vite server verify snippet save, favorite reordering and dark/light compact
layouts. They use in-memory data, never the user's library or clipboard. Actual native chooser,
open/reveal and paste behavior remains unverified; no development server was manually controlled.
