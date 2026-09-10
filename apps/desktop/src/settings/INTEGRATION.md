# Settings extraction handoff

## Implemented

- Extracted the live PreferencesView into `SettingsView.tsx` with explicit `SettingsViewProps` and `SettingsPreferences`; removed the unused LegacyPreferencesView and its inferred props contract.
- Moved settings section metadata into `settingsNavigation.ts`. Removed obsolete settings-only shortcut helpers and AiSettings import from App. App retains preference persistence, native state, shared keycap presentation, and its settings artwork used by command results.
- App now imports SettingsView and passes `CommandGlyph={CommandGlyph}`. This injected renderer preserves native icon/cache behavior without a circular App import. All existing callbacks remain unchanged.
- Grouped sidebar navigation into Preferences, Tools, and Privacy. Search matches all query words across English/Korean section labels, descriptions, control names, and built-in/system/window command titles. Search filters sections, keeping the complete control panel for a matching section; it does not filter individual control rows or installed application records.
- Search preserves the selected section when clearing a temporary filter, shows an empty result state without stale controls, and handles Escape before closing settings. Native AI/application navigation and the window-layout Permissions link clear incompatible filters.
- Added named navigation/control groups, h3 group headings, a named content region, accessible command rows, and keyboard navigation for theme radios. Retained existing class names and confirmation/focus behavior.
- Added local composition guards for Escape, shortcut recording, and script-directory Enter. Existing App interaction guards continue to operate.

## Coordinator integration

The SettingsView import, JSX rename, and CommandGlyph prop are already applied in App. No further extraction edits are needed there.

`clipboardDetails?: ReactNode` is available and currently renders after the existing Clipboard History enable/clear group, as initially requested. The new ClipboardSettings module now appears to own enable/clear itself; injecting it as-is would duplicate those controls. Before wiring it, render the supplied node as an override of the existing clipboard section, retaining the current controls only as the fallback when the node is absent. Root owns this final integration decision; no clipboard backend or component files were edited by this worker.

Optional follow-up: App may import `SettingsPreferences as Preferences` and `ThemePreference` from SettingsView to unify its structurally identical persistence type. No settings imports depend on App.

## CSS hooks

Existing settings classes are preserved. Root owns `styles.css`.

- `.settings-search` is reused alongside `.settings-filter`; reconcile their width, margin, and padding rules for the sidebar.
- `.settings-nav-group`: vertical grouping and spacing between related navigation entries.
- `.settings-nav-group-title`: compact muted heading; reset default h3 margins and weight.
- `.settings-search-status`: compact result count or empty-state status.
- `.settings-group-title` now uses h3 elements; reset their default margin/font styles while retaining the existing spacing.
- Sidebar navigation remains native buttons with `aria-current="page"`, grouped by named `role="group"` containers.

Grouping was informed by the [shadcn Sidebar composition reference](https://ui.shadcn.com/docs/components/sidebar), using its separation of header, content groups, and footer. No shadcn or Tailwind dependency was introduced.

## Locale additions

No shared locale file was edited. Add the following English/Korean pairs in `src/locales/messages.json`; every rendered string goes through existing `t()`.

| English key | Korean value |
| --- | --- |
| Tools | 도구 |
| Search settings | 설정 검색 |
| Search settings… | 설정 검색… |
| No settings found | 검색된 설정이 없습니다 |
| Try another setting name or keyword. | 다른 설정 이름이나 검색어를 입력해 주세요. |
| {0} settings sections found | 설정 섹션 {0}개 검색됨 |
| {0} shown | {0}개 표시 |
| Searching… | 검색 중… |
| Active | 활성 |
| Allowed | 허용됨 |

Preferences and Privacy already have translations. AI stays identical in both languages. Search-only keywords include bilingual aliases and do not introduce additional displayed copy.

## Verification

Passed on the integrated checkout:

```sh
pnpm --filter @prism/desktop exec vitest run src/App.test.tsx src/settings/SettingsView.test.tsx
# 2 files passed; 51 tests passed (44 App, 7 SettingsView)
pnpm --filter @prism/desktop typecheck
# passed
```

Settings tests cover English/Korean control and window-command search, empty results, search Escape, composition Escape, named navigation/control groups, clipboard injection, native AI navigation, theme radio keyboard focus, and permission navigation from a filtered section. Existing App tests cover the native-settings route, localized UI, shortcut recording, IME script entry, confirmation focus recovery, and shared native icon rendering.

An earlier run was temporarily blocked by the other worker's missing LibraryRunDialog module; that file landed and both commands passed afterward. The accidentally broader first test invocation also passed 141 unrelated tests but could not import App/Library at that intermediate point; the final evidence is the two targeted commands above.

No development server was started, stopped, or restarted; no user app was launched or killed; no paid AI, commit, push, publication, or deployment was run. Browser appearance, real IME/device interactions, native permission dialogs/global shortcuts, and packaged separate-window presentation remain unverified. Palette styling, new locale entries, and the clipboard override should be checked again after coordinator integration.
