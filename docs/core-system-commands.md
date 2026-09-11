# Core system commands

Prism exposes Sleep, Sleep Displays, Restart, Shut Down and Log Out through OS-specific adapters. Windows supports all five; Linux display sleep requires X11 and graceful logout requires GNOME or KDE. See [Desktop platforms](desktop-platforms.md) for the support matrix and verification limits. They are searchable in English and Korean and use the existing command alias, global shortcut and disable controls. Settings destinations and Lock Screen retain their existing platform support. Browser previews show the catalog but cannot execute native actions.

Restart, Shut Down and Log Out require a native confirmation with an action button and Cancel. Cancellation leaves the palette open. Only one power request can be pending. macOS receives normal session Apple Events, allowing applications to handle unsaved documents; Sleep Displays uses the fixed `/usr/bin/pmset displaysleepnow` invocation. The renderer supplies an allowlisted command ID and display language, never a program, script, event code or shell argument. A successful dispatch indicates a submitted request, not completion of an OS transition.

## Raycast import coverage

Classic `builtin_command_` IDs and explicitly supported `c:r:<package>::*::<command>` IDs resolve to the same Prism command. Both hotkeys and aliases use the existing preview, conflict resolution, journal, apply and undo paths. Importing a shortcut never executes its target command.

| Package | Supported command names |
| --- | --- |
| `system`, `systemActions` | `lockScreen`, `sleep`, `sleepDisplays`, `restart`, `shutDown` / `shutdown`, `logOut` / `logout` |
| `clipboardHistory` | `clipboardHistory` |
| `emoji` | `searchEmoji` |
| `fileSearch` | `fileSearch`, `searchFiles` |
| `snippets` | `searchSnippets` |
| `quicklinks` | `searchQuicklinks` |
| `raycastPreferences` | `openPreferences`, `showPreferences` |
| `open-ai` | `aiChat` |
| `windowManagement` | Existing supported window command names |

Unknown packages, extension IDs, forced/immediate power variants and unavailable platform targets remain unsupported rows. Package-qualified IDs are matched by both package and command, never just a leaf name. Power command previews show readable titles. The tests use independently constructed exports; coverage of every Raycast version or undocumented command spelling is not claimed. Settings and AI mappings open Prism's corresponding views; they do not import Raycast preferences or AI histories.

## Focused launcher comparison

The comparison uses the projects' own documentation and the current Prism code, not a claim of equivalent quality or complete compatibility.

| Common workflow | Reference behavior | Prism decision |
| --- | --- | --- |
| System actions | [Raycast](https://manual.raycast.com/system-commands) lists sleep, display sleep, restart, shutdown and logout; [SuperCmd](https://github.com/SuperCmdLabs/SuperCmd#key-features) lists power/session commands | Provide five OS-routed actions, with confirmation for session-ending requests |
| Everyday launcher tools | [Asyar](https://github.com/Xoshbin/asyar#features) and [SuperCmd](https://github.com/SuperCmdLabs/SuperCmd#key-features) include app/file search, clipboard history, snippets, links and window management | Reuse Prism's existing providers and native implementations; expand import connections |
| Migration breadth | [SuperCmd's importer](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/main/raycast-config-import.ts) covers additional data categories; [Asyar's guide](https://github.com/Xoshbin/asyar/blob/main/docs/guide/features/raycast-import.md) describes compatible-item migration | Keep preview/conflicts/recovery. Expand compatible command IDs without introducing extension, notes or history migration |

Deferred: media/volume controls, system appearance toggling, trash operations, app quit-all commands and extension-runtime parity. Prism's own appearance cycle is not a substitute for the macOS appearance toggle. Sleep Displays is the small additional everyday gap filled in this pass.

## Verification (2026-09-11)

- Full desktop suite: 47 files, 532 tests passed. System command ranking is checked across macOS, Windows and Linux catalogs.
- Desktop TypeScript and native macOS `cargo check --lib --locked` passed. The native suite passed 222 tests with 5 ignored. Windows application/test cross-compilation and Linux adapter checks are detailed in [Desktop platforms](desktop-platforms.md).
- Five isolated Rust tests cover exact IDs, non-forced event plans, cancellation without execution, single dispatch and error propagation. Both confirmation and OS execution are substituted; no power requests are sent.
- Orca's existing browser tab and Vite server on port 1420 were reused. Sleep and Sleep Displays appeared in real search results. A synthetic file preview showed 7 supported aliases and 1 unsupported package, readable power command titles, and a disabled import button in the browser. No browser console errors or warnings were reported; only Vite and React development messages appeared.
- Physical sleep/restart/shutdown/logout/display sleep, the native confirmation window, actual hotkey activation and migration into the installed app were not exercised. The installed app, signer, permissions and running development server were preserved.

See [Raycast migration](raycast-migration.md) for export decoding, conflict and recovery details.
