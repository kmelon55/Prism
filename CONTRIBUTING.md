# Contributing to Prism

## Language for Git workflow

Use English for every artifact that appears in the Git hosting workflow:

- branch names;
- commit subjects and bodies;
- pull request titles and descriptions;
- code review summaries;
- release notes and changelog entries.

Documentation and product copy may use the language appropriate to their audience. The English rule above specifically keeps repository history and collaboration metadata consistent.

Prefer a short imperative commit subject such as `Improve keyboard result navigation`. Explain the reason and verification in the body when the change is not self-explanatory.

## Before proposing a change

Run the checks that apply to your change:

```bash
pnpm typecheck
pnpm test
pnpm build
```

Native changes also require `cargo check` or a Tauri build on a machine with the Rust toolchain installed.


## Installed app and releases

Use the installed Prism app for daily work and receive changes through GitHub Releases.
See [the release guide](docs/releases.md). Preserve existing development servers;
do not start, restart, or stop them without an explicit request. Do not create
separate Prism Test bundles or change the stable application identifier.
