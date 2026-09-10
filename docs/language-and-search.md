# Language, direct search, and AI file access

Updated: 2026-09-08.

## Language

Settings → General → Language offers System, English and Korean. System follows the WebView's
preferred language (Korean for `ko-*`, English otherwise). The choice uses the existing preferences
store and native cross-window notifications. Open screens update immediately; reload retains the
choice. `html.lang` follows it as well. Settings, command/action labels, AI controls, library editors,
confirmation/accessibility labels and known native diagnostics use the shared message catalog.
System file-dialog controls themselves follow macOS; Prism-owned picker titles use the app language.

Product text is translated through explicit `t` calls, never DOM rewriting. User-supplied entry and
application names, paths, aliases, conversation titles/content and model output are preserved.
Built-in command names remain searchable in both languages. Command IDs and section membership are
independent of translated labels. Native diagnostic lines are translated while endpoint/status/ID
values are retained. Unrecognized external error text is preserved rather than guessed.

## Direct access and file search

Quicklinks and Snippets each have their own palette command, opening directly to their editor/list.
Library remains the shared management surface; opening it is not a prerequisite for using saved
entries. Files appear alongside applications and commands when a filename is typed into the root
palette. File results include their path to distinguish identical names.

On macOS, filename queries use the existing Spotlight index under the current home folder. This
works with no Library roots configured. It reads names and filesystem metadata, not file contents,
and does not grant the AI permission to read anything. `mdfind` receives separate arguments without
a shell, uses NUL-delimited paths, and is bounded to three seconds/1 MiB/400 accepted results. Hidden
paths, application bundles and generated/dependency directories are excluded. Open/reveal/copy
revalidate the canonical current-home boundary and file existence. Spotlight exclusions and indexing
status affect discovery; unindexed files can be covered by explicitly added folders.

Previously selected Library folders add the existing bounded local filename index. It is refreshed
explicitly and supports paths outside Spotlight's home scope. Filename comparison now normalizes
Unicode, including macOS decomposed Korean filenames. Queries debounce, publish independently from
other providers and ignore stale results. The file provider has a five-second deadline. The current
selected-folder scan still has the existing depth/entry cap and no filesystem watcher.

## AI file activation

Previously, a global allow flag plus at least one selected folder were both required, while the
composer button was disabled without explaining or resolving the missing condition. Clicking Files
now refreshes current native settings. If no folder is granted, it opens a native folder picker;
choosing a folder both grants that folder and enables local reading. Canceling leaves Files off.
If folders exist but reading is off, the explicit Files click enables reading for those grants.
No files or queries are sent until the user sends a chat message.

The Settings allow switch follows the same first-folder flow. Native setting writes notify all
windows; revocation remains enforced during requests. Failed reads/picker operations show a retryable
error and release the button. Duplicate clicks and sending while the picker is active are blocked.
Launcher search folders and AI folder permissions remain separate.

## Verification

The automated suite includes language selection/remount, native and storage notification paths,
bilingual command ranking, preservation of user labels/interpolated values, root file search without
configured folders, decomposed Korean filenames, direct quicklink/snippet navigation, and AI folder
activation/cancel/error recovery. Browser checks use in-memory native IPC on the existing Vite server:
Korean-to-English settings switching, English AI tools, Files activation and root filename results.
A read-only real Spotlight query also found `docs/local-library.md` in this checkout.

This does not prove the native file-picker interaction, cross-WebView delivery in the packaged app,
or live provider reading of granted files. No paid inference, user-file mutation, server restart,
commit or deployment was performed. See implementation-status.md for final test/build counts.
