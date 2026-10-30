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
cd apps/mac
swift build
swift test
```

Release script changes also need `node --test scripts/*.test.mjs` from the repository root. Android changes follow
[`apps/android/README.md`](apps/android/README.md).


## Installed app and releases

Use the installed Prism app for daily work and receive changes through GitHub Releases.
See [the release guide](docs/releases.md). Development builds run as "Prism Dev" with their own bundle identifier
and data, beside the installed app; do not create other test bundles or change the stable application identifier.
