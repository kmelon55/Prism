# Raycast migration and window management

Settings → Backup & Restore now offers a Raycast import review. Choose a `.rayconfig` or JSON export, enter its export password when required, select compatible items, and apply them together. Existing settings are kept by default. Shortcut and alias replacements require selecting their individual conflict rows.

## Supported imports

| Source | Behavior |
| --- | --- |
| Classic JSON/gzip `.rayconfig` | Read supported built-in packages and root-search customizations |
| Classic encrypted `.rayconfig` | Decode IV-prefixed AES-256-CBC with SHA-256 password derivation |
| Schema 1/2 `.rayconfig` | Decode the gzip envelope; support clear payloads and scrypt/AES-GCM encryption with 12- or 16-byte IVs |
| Raycast X schema 3 `.rayconfig` | Read the `RAYCFG3` container, compressed header and payload; prompt for encrypted exports and authenticate their trailing AES-GCM tag |
| Snippet / quicklink JSON arrays | Preview text, supported expansion keywords, and HTTP(S) links |
| Classic launcher hotkey | Offer an explicit replacement of the current launcher hotkey |
| Command hotkeys and aliases | Match supported Prism built-ins and indexed application paths; report unresolved commands |
| Window command hotkeys | Match supported half, third, quarter, sixth, fourth, size, position and display command names |
| System and common built-in commands | Map supported classic and package-qualified IDs for power/session actions, clipboard, emoji, files, snippets, quicklinks, settings and AI Chat; see [exact coverage](core-system-commands.md#raycast-import-coverage) |

Passwords are used only for local decoding and are cleared from the form. File and decompressed payload limits are 20 MB; the review is limited to 3,000 items. Unsupported versions, malformed encryption fields, unknown modifiers and multi-step hotkeys are rejected. Crypto dependencies load only when decoding requires them.

Schema 3 uses an eight-byte `RAYCFG3\n` signature, a little-endian 32-bit compressed-header length, a gzip JSON header, and a gzip payload. The header contains `schemaVersion: 3` and optional `encryption` metadata (`iv` and `salt` in hex). Encrypted payloads end with a 16-byte authentication tag and use scrypt (N=16384, r=8, p=1) with AES-256-GCM. Compressed and decompressed headers are bounded to 1 MB. This framing was checked against the installed Raycast export implementation; regression fixtures are generated synthetically and contain no user export data.

Quicklink query tokens are normalized to Prism's `{query}`. Unsupported placeholders are reported rather than silently changing their meaning. Snippets with incompatible expansion triggers can retain their text; the omitted trigger is listed separately. Installed-app resolution performs targeted searches beyond the application's first 100 search results.

Window command imports accept both legacy `c:r:windowManagement::*::...` and current `c:r:window-management::-::...` identifiers. `moveNextDisplay` and `movePreviousDisplay` resolve to Prism's existing display-movement commands. Window hotkeys and aliases retain conflict, disabled-command and platform checks; extension commands and custom-layout identifiers do not resolve merely by sharing a built-in name.

Custom Raycast window layouts, extension installation/preferences, scripts, AI histories, clipboard history, notes and MCP configuration are outside this import. This is a compatible-item migration, not a complete Raycast runtime or configuration clone. Native permission grants are never imported or requested by the importer.

## Apply and recovery

Before the first data write, Prism saves `raycast-import-recovery-v1.json` in its native configuration directory. It contains the selected values and original shortcuts/aliases, never the export password. The file is private to the user on Unix. A failed recovery write prevents application. An existing recovery record must be reviewed and explicitly discarded before another migration can start.

Application uses the existing shortcut registrar, preference persistence and library validation. Every item rechecks conflicts at application time, including changes since review. Failures are reported per item; successful items remain applied. The operation is recoverable, **not** an atomic transaction across all stores.

Undo restores imported values only if they still match the import. Later user edits and newly favorited library entries are preserved. Pending records support recovery after interruption between a data write and its progress marker. Repeated imports skip existing library entries. Recovery can be retried or explicitly discarded.

## Window behavior

The native window manager now exposes 37 commands. In addition to the existing layouts, it includes width/height maximization, reasonable size, vertical fourths, edge movement, and previous/next display movement.

- Repeating Left Half or Right Half cycles `1/2 → 1/3 → 2/3 → 1/2` by default. The order can be reversed or cycling disabled.
- The cycle belongs to the same focused window and command. Switching windows, using another command or manually changing geometry resets it.
- Restore returns to the geometry before a continuous cycle, including when the sequence wraps back to half.
- Window gaps and screen-edge gaps are independent, bounded to 0–64 logical pixels. Almost Maximize is adjustable from 50–100%.
- Display movement preserves logical window size where possible and clamps it to the destination work area. Display order follows monitor position and wraps.
- Native options persist in `window-management-v1.json`. Browser controls are an interactive preview and do not save native settings.

Settings retain the existing layout, remove redundant explanatory copy, use restrained prism colors for selected controls, and group the command list with filters. Backup details remain available in a disclosure.

## Verification

- Current window identifiers (2026-09-11): a real decrypted Raycast 2.3.0.0 export exposed 12 unsupported window hotkey/alias rows. A fixture reproducing those command identifiers and bindings displayed 12 ready, zero conflicts and zero unsupported rows in the updated Orca preview. All 48 focused import tests passed, including mocked shortcut registration and undo.
- Schema 3: the same real encrypted export returned `invalid` in the previous decoder and `password` in the updated decoder, then displayed its review after the user unlocked it. Synthetic encrypted fixtures additionally verify wrong-password feedback, successful decryption, malformed framing and size bounds. No user export data is committed.
- Release validation: 555 desktop tests, 36 command-core tests and 225 Rust tests passed; five opt-in Rust tests were skipped. Coverage includes encrypted fixtures, conflict review, interrupted recovery, subsequent edits, native registration failures, window geometry/cycling/options and browser-only controls.
- Desktop TypeScript and production bundle passed. Vite reports a large-chunk advisory.
- Orca's embedded browser: real test-file selection, wrong-password feedback, successful encrypted-file review, unsupported rows, disabled browser application, window-cycle preview, Korean UI and both themes. No browser console errors or warnings were observed.
- The schema 3 and current-command checks reused Orca's existing offline preview. No development server was started, stopped or restarted. The installed `/Applications/Prism.app` was not replaced, restarted or re-signed; TCC grants were unchanged.

Synthetic exports establish parser behavior; no claim is made that every historical Raycast export schema is covered. Actual native hotkey activation, multi-monitor geometry and migration into the installed app remain unverified because that app was intentionally left untouched.

## Browser captures

- [Window settings, Korean/dark](evidence/raycast-migration/window-settings-ko-dark.png)
- [Encrypted-file import review](evidence/raycast-migration/encrypted-import-preview.png)
- [General settings, Korean/light](evidence/raycast-migration/general-settings-ko-light.png)

## References

- [Raycast import/export](https://manual.raycast.com/import-export) and [window management](https://manual.raycast.com/window-management): product behavior and export scope.
- [SuperCmd import implementation](https://github.com/SuperCmdLabs/SuperCmd/blob/2da7b9e5dec0199a972a59cece402c85f729d5d7/src/main/raycast-config-import.ts): command mapping, conflict reporting and staged import behavior.
- [Asyar import guide](https://github.com/Xoshbin/asyar/blob/95819f4ca5928b777cb5b8390680d90143067198/docs/guide/features/raycast-import.md) and [format reference](https://github.com/Xoshbin/asyar/blob/95819f4ca5928b777cb5b8390680d90143067198/asyar-launcher/src-tauri/src/raycast_import/mod.rs): format interoperability research. Prism's code and synthetic tests were written independently; no Asyar implementation or fixtures were copied into the repository.
