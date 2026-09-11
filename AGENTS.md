# Repository instructions

- Preserve any development server the user already has running. Do not start, restart, or stop a development server unless the user explicitly asks for that exact action.
- Inspect `git status` before editing and preserve unrelated user changes.
- Write all Git-facing project artifacts in English. This includes branch names, commit subjects and bodies, pull request titles and descriptions, review summaries, release notes, and changelog entries.
- Use concise imperative English for commit subjects, for example: `Add native application provider`.
- Do not commit, push, create a pull request, deploy, or publish unless the user explicitly requests it.
- Preserve the installed macOS signing identity. Use `pnpm macos:install` for an authorized local app replacement; never overwrite `/Applications/Prism.app` with an ad-hoc build or a different signer.
- Keep signing certificates and their private keys persistent and outside the repository. Never regenerate a certificate as part of a build, reset TCC, or weaken Keychain access controls to avoid permission prompts.

## Persistent browser and Computer Use policy

- This is a standing user instruction for all projects and future sessions. Keep it in effect unless the user explicitly changes it. A request to use an external browser or Computer Use authorizes only that requested scope; it does not permanently relax this policy.
- For browser interaction and web development verification, use only Orca's embedded browser through the `orca-cli` skill. Read its version-matched browser reference before controlling tabs. Reuse the user's running development server and the relevant Orca tab when available.
- Do not use Computer Use, desktop automation, the user's personal browser, external Chrome/Safari/Edge windows, or the Codex/ChatGPT in-app browser unless the user explicitly requests that specific surface or capability. The Codex/ChatGPT in-app browser is not Orca's embedded browser.
- Do not launch or attach to an external browser through Playwright, CDP, agent-browser, browser plugins, shell launch commands, AppleScript, or another fallback. Tool availability, a generic request to test a website, and automation instructions in a skill are not authorization to leave Orca.
- If Orca browser automation is unavailable or fails, report the exact limitation and continue checks that do not require a browser. Do not enable Computer Use or external browser plugins, change this policy, or switch to another browser to finish the task.
- Keep the Chrome, Browser, Computer Use, and Unified Computer Use plugins and dedicated Computer Use/browser MCP runtimes disabled unless the user explicitly authorizes their use or asks to change these settings. Do not silently restore them during setup, upgrades, or troubleshooting.
