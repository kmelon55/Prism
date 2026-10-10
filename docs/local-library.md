# Local library and clipboard actions

Search **Notes / 노트**, **Quicklinks / 링크** or **Snippets / 스니펫** to open that feature directly, or **Library / 보관함** to manage them. Saved entries also appear directly in launcher search.
Links and snippets use the compact library editor; closing an unsaved editor asks whether to save,
discard or keep editing. A failed save preserves the input.

Notes open a dedicated two-pane workspace: a searchable list and one borderless Markdown document.
**New note / 새 노트** opens a blank document directly. The first nonempty line supplies the list title
(with Markdown heading markers removed). There is no separate title field. The eye button previews
headings, lists, task lists, tables and code blocks; returning to editing preserves the exact source.
Legacy separate titles are retained as a Markdown heading when the note is edited.

Every edit starts an automatic SQLite save. Writes run serially and coalesce newer pending edits;
typing remains enabled during saves. Switching notes or using Back/Escape waits for the latest write,
without Save/Cancel buttons or a discard dialog. A failed save retains the editor and exposes Retry
save; subsequent editing also retries. Heading-only notes and clearing existing notes are supported.
Untouched blank notes are not created. Pending writes continue on surface unmount; crash recovery
for failed writes is not implemented. Markdown source is stored in the library, not as separate `.md` files.

Root search matches the complete body, including text beyond the 140-character result preview,
using the shared Korean-aware matcher. Selecting a note opens its editor; the launcher Copy action
copies its literal body. Notes do not expand snippet placeholders or accept snippet abbreviations.
They share the library capacity limits below and can be favorited through the launcher action menu.

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

Versioned backup/recovery supports notes, snippets, HTTP(S) quicklinks and favorites, with a reviewed
conservative import and a separate allowlisted preference restore. See [backup recovery](backup-recovery.md).
Notes are selected by default for backup. Exports containing notes use format version 3; exports
without notes retain version 2, and this app can still import versions 1 and 2. Older apps reject
version 3 with an update-required error rather than silently losing notes.

## Clipboard and paste

Clipboard history is opt-in, text-only and persisted locally with retention and pins. Copy keeps Prism open. Individual deletion
removes only the selected history record. Paste and snippet paste require macOS Accessibility access,
a live captured application, and the same focused window as when Prism opened. Prism copies the
text, activates that target and rechecks it before sending Command+V. A target change aborts the
injection and restores Prism; copy remains available. Clipboard contents may already have changed
when a late activation error occurs, which the error explains. Other platforms expose Copy fallback.

## Verification

The notes tests cover serial autosave, continued typing during persistence, switching notes and
closing after the latest write, failed-save retention/retry, first-line titles, legacy title preservation,
untouched blank documents, clearing notes, Markdown rendering/source retention, deletion, Korean
normalization/composition, command navigation, SQLite limits and backup compatibility.
The Orca browser preview on the existing Vite server uses isolated localStorage and mocked IPC;
it does not modify the installed application's library. Native installed-app interaction remains
unverified. No app replacement or release was made.

React tests use mocked IPC for save failure, unsaved-editor recovery, deletion, stale file results,
pinning/restoration and clipboard copy/delete. Rust tests use isolated SQLite and temporary files for
record validation, roundtrip/update, filename indexing and revoked-root/traversal checks. Browser
fixtures on the existing Vite server verify snippet save, favorite reordering and dark/light compact
layouts. They use in-memory data, never the user's library or clipboard. Actual native chooser,
open/reveal and paste behavior remains unverified; no development server was manually controlled.
