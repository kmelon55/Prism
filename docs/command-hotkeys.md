# Command hotkey presentation

Window-management, installed-application and system hotkeys execute through the existing command handler without first showing or focusing the main palette. Preferences opens its dedicated settings window; Hide does not briefly show a hidden palette. Interactive commands such as clipboard history, files, snippets, emoji and AI Chat still open the palette. Dictation retains its native overlay path.

Before a background command is dispatched, Prism captures the external foreground target. If the main palette is already focused, it preserves the target captured when the palette opened. Existing command validation, disabled-command checks, window layout cycling and system confirmations remain in their original handlers.

The command event marks background execution. Failures reveal the palette with the existing error message; successful actions and cancelled system confirmations do not reveal it. A missing application also produces a visible error instead of disappearing silently.

Regression checks cover repeated Right Half dispatch, delayed native refusal, unapplied layouts, application launch and disappearance, dedicated Settings, disabled window commands and cancelled system confirmation with mocked native IPC. Rust checks distinguish background command families from interactive palette commands. These checks do not establish physical shortcut or installed-app flicker behavior; the installed app was not replaced or restarted during this fix.
