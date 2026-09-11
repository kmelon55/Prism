# Desktop platforms

Prism selects native implementations at compile time and desktop-session capabilities at runtime. Users do not choose an OS backend. macOS keeps its existing native implementations, signing identity and permission model. The Windows and Linux adapter crate lives in `packages/desktop-platform`; search, aliases, shortcuts, command policy, layout calculations and data storage remain shared.

## Implemented coverage

| Workflow | Windows | Linux |
| --- | --- | --- |
| Application search and launch | Start Menu shortcuts plus the Windows AppsFolder namespace, including Store apps; ShellExecute | XDG application directories, Flatpak/Snap exports; GLib desktop entry parsing and launch |
| System settings and lock | Existing native settings allowlist and session lock | Existing desktop-specific settings and lock routes |
| Sleep, restart, shut down | Native power/session APIs, normal session close requests | login1 D-Bus, with interactive authorization and inhibitors handled by the service |
| Log out | Normal Windows session request | GNOME or KDE session manager; hidden on other desktops |
| Sleep displays | Windows monitor-power request | X11 DPMS; hidden on Wayland |
| Window layouts | Win32, all 37 existing layout actions | X11/EWMH with RandR monitors; hidden on Wayland |
| Window cycling, gaps, restore, display transfer | Shared geometry and preferences | Shared geometry and preferences |
| File open/reveal and raster preview | Associated application, Explorer selection, shared image preview | Associated application, FileManager1 selection with folder fallback, shared image preview |
| Clipboard text/image history and copy | arboard with image support | arboard, retaining selection ownership; Wayland requires a supported data-control protocol |
| Paste into another app | Target HWND/PID validation, foreground check, clipboard sequence/content guard, Ctrl+V | X11 target/PID, foreground, selection owner/content guard, XTest Ctrl+V |
| AI key storage | Windows Credential Manager | Secret Service, e.g. GNOME Keyring or a compatible desktop vault |
| Raycast command aliases/hotkeys | Maps supported commands to Windows implementations | Maps supported commands; session-unavailable window/power rows are skipped |

Window adapters read back the applied geometry, retain actual bounds for cycling, reject an unchanged refused layout and keep the previous layout on failures. App minimum-size constraints can produce a different size from the requested layout. Windows foreground restrictions and elevated applications can prevent paste; Prism reports the failure and retains the copied item. There is no elevation bypass.

Restart, shut down and log out use the existing native confirmation and single-pending-action guard. Cancel never reaches the OS adapter. The renderer passes only fixed command IDs. No forced termination, shell interpolation or arbitrary power command arguments are exposed.

Secret storage never falls back to plaintext. Linux status checks use Secret Service `SearchItems` without unlocking the vault or fetching secrets. Explicit use/unlock/save actions access the vault. A missing or locked service produces an actionable error.

## Remaining platform differences

- Wayland does not provide the X11 mechanisms for controlling arbitrary application windows or injecting input. Prism does not advertise these through XWayland merely because `DISPLAY` exists. Use explicit Copy and the desktop's own window controls. Clipboard availability also depends on the compositor's supported protocols.
- Ordinary global hotkeys use the existing Tauri plugin. On Wayland, desktop support varies; the existing shortcut recovery flow remains available. A desktop shortcut that launches Prism can activate its existing single instance.
- Whisp/Swift dictation, automatic snippet expansion, double-modifier shortcuts, file-reference clipboard reuse and native application icon extraction still have macOS-only implementations. Manual snippet selection, text/image copy and supported paste are covered above. This change does not claim full native feature parity.
- macOS Spotlight is not available on other systems. Windows/Linux use Prism's registered-folder file index.
- A Linux desktop must supply a D-Bus session, a compatible secret store, GLib, the normal desktop opener and the services required by the selected action. Power permissions, hardware sleep support, X11 extensions and window-manager policies still apply.
- Raycast imports preserve physical modifier semantics: Command becomes Super (the Windows key on Windows). Review the displayed shortcut before importing; Prism does not silently substitute Control or bypass reserved OS shortcuts.

## Packaging and CI

`tauri.windows.conf.json` adds a current-user NSIS installer that provisions WebView2 when needed. `tauri.linux.conf.json` adds deb, rpm and AppImage targets. Tauri automatically merges the matching OS configuration. The macOS bundle configuration is unchanged.

The new `desktop-platforms.yml` workflow builds Windows and Ubuntu installers and runs native tests on those runners. It uploads build artifacts only. It does not publish releases, change signing identities or modify the macOS release workflow. Windows/Linux updater artifacts are disabled until their release/signing distribution is configured. These are build configurations, not already published installers.

## Verification on 2026-09-11

- macOS: application `cargo check --lib` passed; native unit suite passed 222 tests with 5 ignored. These are not physical window/input/power tests.
- Windows: the whole application and its test code passed cross-target `cargo xwin check --target x86_64-pc-windows-msvc --tests`; the adapter also passed the GNU Windows target check. macOS-only unused-code warnings remain on Windows.
- Linux: the independent native adapter passed `cargo check --target x86_64-unknown-linux-gnu`. The full GTK/WebKit application build and package installation require a Linux runner; the new workflow has not been executed from this checkout.
- Frontend: all 532 tests in 47 files passed. TypeScript passed. Power search ranking is checked across all three OS catalogs.
- Orca's existing tab loaded a static bundle of the actual UI. Native IPC remained absent; Windows and Linux user-agent previews showed their system catalogs and Sleep search results. The observed console was empty. The existing port 1420 server was no longer listening during this pass, so no server was started or restarted.
- No sleep, restart, shut down, log out, display sleep, native input injection, vault mutation or installed-app replacement was performed for validation. No Windows/Linux machine or VM session was available. Actual desktop behavior, installation and signed release delivery remain unverified.

Local build tooling added for verification: Rust Windows/Linux targets, `cargo-xwin`, the Rust LLVM tools component and keg-only Homebrew LLVM. They do not replace Apple's compiler or change the shell profile. Temporary SDK/build caches stay outside application data and signing storage.

## References

Architecture was researched independently; no GPL source, UI, assets or fixtures were copied.

- [Asyar at c8e27d8](https://github.com/Xoshbin/asyar/tree/c8e27d8985275d39b35ade9b3176949f232cfc6c): common layout policy with OS-specific mechanisms; its Linux window support also distinguishes X11 from Wayland.
- [Tauri architecture](https://v2.tauri.app/concept/architecture/): a shared frontend and Rust core do not replace the host's system APIs.
- [Windows SetSuspendState](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-setsuspendstate), [ExitWindowsEx](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-exitwindowsex) and [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).
- [EWMH specification](https://specifications.freedesktop.org/wm-spec/latest/), [login1 D-Bus interface](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html), [Secret Service API](https://specifications.freedesktop.org/secret-service/latest/).
- [keyring 3.6.3](https://docs.rs/keyring/3.6.3/keyring/), [x11rb 0.13.2](https://docs.rs/x11rb/0.13.2/x11rb/), [Gio DesktopAppInfo](https://docs.rs/gio/0.18.4/gio/struct.DesktopAppInfo.html).
