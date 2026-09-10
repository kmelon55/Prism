# Desktop quality gates

Updated: 2026-09-06 · Applies to [product specification](product-spec.md) P01–P12.

Every check below is **Not run** at creation. Source inspection, an existing test, a screenshot,
a web build, and packaged native behavior are distinct evidence. Do not convert this checklist
to Passed by inference. Record build/source identity, platform, scenario, actual result, and artifact.

The first automated interaction/search subset is recorded in [implementation-status.md](implementation-status.md).
Its mocked-IPC results do not mark the full native scenario groups below as Passed.
The 2026-09-09 [foundations implementation](foundations-implementation.md) records search,
file, emoji, clipboard, script, backup and date/time evidence, plus the automatic-expansion gate.

## 1. Evidence and severity

| Evidence level | Establishes | Does not establish |
| --- | --- | --- |
| Source | A path or gap exists in the inspected tree | Correct runtime behavior |
| Unit/contract | Deterministic logic and guarded failure cases | OS focus, permission dialogs, real paste |
| Existing browser preview | Rendered states, navigation, non-native interaction | Native app discovery or packaged performance |
| Local native bundle | OS behavior with the recorded app identity | Production bundle independence or other OS support |
| Packaged release build | The recorded full app runs with bundled assets | Signing/distribution readiness unless separately tested |

Critical: wrong-app paste/expansion, unauthorized execution/capture, unrecoverable user-data loss.
High: launcher unreachable, common task failure, IME accidental execution, broken retention/privacy,
lost configuration, or repeat execution. Medium: confusing feedback, visual inconsistency, or
recoverable uncommon-case failure. M3 requires no open Critical/High defect. Any Medium exception
must name its affected scenario and workaround; exceptions cannot redefine the selected baseline.

## 2. Reproducible fixtures

Create original deterministic fixture data during implementation, under
`packages/command-core/src/` for ranking and a dedicated desktop test fixture directory for UI.
Never copy reference product tests/data. Native cases use a separate temporary test directory and
throwaway documents; never modify the user's working documents to prove an action.

| Fixture | Contents | Required observation |
| --- | --- | --- |
| Search | Synthetic apps Paper Editor, Paper Notes, Calendar, Calculator; titles containing Hangul; two identical display names at distinct paths | Exact `Paper Editor` wins over prefixes; `ped` finds Paper Editor; duplicate names expose paths |
| Alias | Assign `cal` to Paper Notes, alongside Calendar and Calculator | Exact alias wins irrespective of recent Calendar launches; duplicate assignment is rejected |
| Usage | Same-tier candidates with controlled usage, plus an unrelated heavily used app | Usage orders within tier; unrelated item never appears; failed launches add no usage |
| Unicode | NFC/NFD variants of the same Korean title; Hangul initial consonants and mixed Latin/Korean input | Full-text equivalents match in M1; initial matching passes in M2; composition commit never executes |
| Async | One immediate provider, one 350 ms provider, one failure, one never-settling provider | Fast results appear independently; deadline surfaces failure; late generation cannot change selected item/action |
| Clipboard | Plain text, 100+ entries, image, file reference, flagged-private item, excluded app, known fake token | M1 cap and M3 cap enforced; excluded payload absent from store/previews/logs; unsupported types explained |
| Files | 100,000 synthetic metadata entries, repeated filenames, Unicode names, missing target, symlink escape, unreadable root | Search bounded; root revocation removes results; execution validates current authorized target |
| User data | Favorites, aliases, 1,000 snippets, links, directories, conflicting shortcuts, malformed/oversized import | Round-trip equality for included fields; invalid import leaves existing state unchanged |

Calculator fixtures, using Prism's own grammar:

| Input | Expected result |
| --- | --- |
| `(18 + 6) / 3` | `8` |
| `0.1 + 0.2` | Display `0.3`, without floating-point residue |
| `1 / 0` | Error, no copyable valid result |
| `8 +` | Incomplete input; no valid result or alarming failure banner |
| `12% of 250` | `30` |
| `3 km to m` | `3000 m` |
| `32 F to C` | `0 C` |
| `2 GiB to MiB` | `2048 MiB` |
| `2026-09-06 + 3 days` | `2026-09-09` |
| `2026-09-06 09:00 Asia/Seoul to UTC` | `2026-09-06 00:00 UTC` |
| DST duplicate/nonexistent local time | Require offset selection / show invalid local time respectively |
| Oversized/deeply nested expression | Bounded rejection; root search stays usable |

The exact decimal display policy and rounding precision belong in P05 implementation documentation;
formatting must not turn overflow or invalid input into a plausible number.

## 3. Functional and native scenarios

All rows start as Not run. Milestones indicate the earliest required pass and any later extension.

| ID | Milestone / requirement | Setup and action | Pass condition and evidence |
| --- | --- | --- | --- |
| QA-01 | M1 / P01 | From browser, editor and document app, summon/type/launch 20 times each; repeat while target already runs | Input focused every time; correct app activates once; palette hides; native recording and counts |
| QA-02 | M1 / P01 | Enter query, Escape twice; open a scoped view and action panel, then back out | Clear → hide at root; nested back restores parent query/selected ID/scroll; keyboard/browser and native evidence |
| QA-03 | M1 / P01 | Compose Korean words, use candidate selection/arrows/Escape and Enter in root, action search and forms | No command triggered by composition; next deliberate Enter executes exactly once; native IME evidence |
| QA-04 | M1 / P01–P02 | Run search/alias/usage/Unicode/async fixtures, navigate while slow results arrive and invoke an action | Correct tier ordering; selected ID stable; no execution of stale rows; exact alias priority; focused automated cases |
| QA-05 | M1 / P02 | Search an action; run calculator copy, clipboard paste and window apply; hold Enter | Correct verbs and shortcuts; root query unaffected by action search; no duplicate action; keyboard and native observations |
| QA-06 | M1 / P02,P10 | Set a shortcut already owned by another test command; inject persistence failure; disable configured command | Previous shortcut/value still works on failure; disabled command has no live shortcut; Settings always recoverable |
| QA-07 | M1 / P10 | Open Settings from selected app; change alias/theme in Settings; close/reopen both windows and restart app | Correct settings row reached; changes synchronized within 250 ms; no root action from settings input; saved state retained |
| QA-08 | M1, extend M3 / P03 | Enable history, copy and find text, delete one entry, clear all, turn off; repeat with pins at M3 | Correct text, clear feedback, deletions scoped correctly, disabling clears and stops capture; inspect native store without exposing payload |
| QA-09 | M1 paste path, complete M3 / P03 | Paste into three test apps; switch app during handoff, close target, deny permission, lock screen | Correct target and single paste; uncertain target causes explicit failure/Copy fallback; zero wrong-target insertion |
| QA-10 | M1 / P04 | Grant/deny/revoke Accessibility; run common layouts and restore on two windows of one app and windows of different apps | Correct window; work-area geometry within 2 logical px when app constraints allow; restore only same target; no mutation on failure |
| QA-11 | M1, extend M3 / P04,P11 | Test all shipped settings destinations; exercise target minimum sizes/full screen; at M3 move between mixed-scale displays and detach a display | Right page opens or actionable error; no unrelated window changes; clamped geometry; no-display case explained |
| QA-12 | M1, extend M2 / P05 | Run calculator fixtures; copy result; then immediately type a non-expression | Correct result/units/date/offset; copy is exact; no stale result; automated parser plus UI/native copy evidence |
| QA-13 | M2 / P06 | Create/edit/restart/open links and chosen local paths; search argument `한글 & x=1`; delete target; enter forbidden scheme | Query encoded once as data; saved changes persist; invalid target/scheme does not execute; native opener observes expected destination |
| QA-14 | M2 / P07 | Index chosen roots; search duplicate names; paginate; open/reveal/Open With/copy path; pause/revoke root; remove target | Correct file and app; no out-of-root action; background work stops; partial results usable; first and last page reachable |
| QA-15 | M1, extend M3 / P01–P12 | Restart with saved config and missing app; start with all hotkeys conflicting; toggle launch at login at M3 | Settings recovery is visible; no silent reset; missing entries identified; login toggle reflects actual registration |
| QA-16 | M2 files, M3 clipboard / P03,P07 | Inject index/store errors, offline volume, locked keychain, retention expiry and capacity pressure | Working sources survive; no plaintext fallback; pins retained; state explains limits; retry does not erase user data |
| QA-17 | M2 / P08,P12 | Create/edit/restart/copy/paste a multiline Korean snippet; search symbol and toned emoji; paste a composed emoji sequence | Exact text/sequence preserved; recent choices persist; draft-loss confirmation; native output in throwaway documents |
| QA-18 | M3 / P03,P08,P10 | Apply excluded-app/private clipboard fixtures; export/import config and snippets with conflicts, malformed data and interrupted writes | Exclusions work before storage; exports exclude keys/history/run output; import atomic and no optional capability auto-enabled |
| QA-19 | M3 / P08 | Expand prefixed keyword followed by Space in three test apps; repeat during IME, secure input, paste, excluded app and target change | One expansion only in valid context; delimiter retained; no capture/injection in excluded contexts; app permission revocation stops expansion |
| QA-20 | M1, extend M3 / P09 | Run original harmless scripts for success, failure, timeout and oversized output; then args containing shell characters, Cancel, changed/deleted target at M3 | Output/status truthful and bounded; argv literal; stale ID blocked; cancel/timeout leaves no owned child process running |
| QA-21 | M3 / P10 | Switch English/Korean/System, grow text to 125%/150%, use keyboard and screen reader, toggle reduced motion/transparency/contrast | No clipped essential controls, lost focus or untranslated critical errors; semantic announcements; visual contrast recorded |

M1 copy-only clipboard cannot pass QA-09 or be labeled full clipboard reuse. Cases that require M3
behavior remain open until implemented. Unit tests of wrappers cannot close native evidence rows.

## 4. Performance budgets and measurement

These are initial Prism budgets. Record actual hardware, OS version, display refresh/scale, power mode,
application count, indexed-file count, clipboard/snippet counts, and complete build identity before
measurement. Use a release bundle with bundled assets, no inspector, and no dependency on a dev URL.
Keep the user's existing development server running unchanged; its presence is recorded as an
environment factor, not permission to stop it. Benchmark code is written independently.

Use a declared Apple Silicon reference machine with at least 16 GiB RAM, 500 app metadata entries,
1,000 snippets and, for M2+, 100,000 file metadata entries. Synthetic metadata measures index load;
real installed apps and chosen roots separately verify native discovery and execution. Report real
counts alongside synthetic counts so fixture throughput is never presented as native discovery proof.
At M1, measure only implemented providers with the app fixture and current clipboard envelope;
add snippet/file loads at M2 and the complete declared dataset at M3. Earlier measurements do not
close the final mixed-provider performance gate.

| Metric | Initial pass budget | Sampling method |
| --- | --- | --- |
| Warm hotkey → visible focused input | p95 ≤ 100 ms | 200 summons; externally observe window/focus, record at ≥120 fps or equivalent monotonic native trace |
| Key input → painted current app/command results | p95 ≤ 80 ms; no sample > 250 ms | 200 edits across at least 50 distinct queries; instrument event, provider completion and next paint |
| Scoped file input → painted first page | p95 ≤ 150 ms; no sample > 500 ms | 200 edits on specified index; include duplicate/nonmatching/Unicode names |
| Cold process → focused usable root from existing catalog | p95 ≤ 1,500 ms | 20 fresh process launches; separately report first-ever empty-index startup |
| First-ever launch → usable built-ins | ≤ 1,500 ms in every sample | Five empty-index launches; indexing progress visible and input never blocked |
| Idle CPU, palette hidden | Mean ≤ 1% of one logical CPU | Three five-minute intervals after index settles; measure process tree; clipboard off/on separately |
| Idle memory footprint | ≤ 350 MiB aggregate | Include app and attributable WebView/helpers with a stated footprint method; after warmup and 30 minutes of mixed work |
| Memory stability | No continuing growth; final settled footprint ≤ warm settled footprint + 50 MiB | 500 summon/search/hide cycles; wait 60 s for settling; explain cache growth within configured bounds |
| Settings cross-window reflection | ≤ 250 ms in all 30 changes | Observe save completion to other window render; no contradictory saved value |

Report p50, p95, maximum, sample count and raw timing artifact. Use nearest-rank percentiles; do not
drop slow samples without documenting an invalid measurement. Distinguish IPC completion from a
painted result. External application launch time is reported separately from Prism dispatch latency.
Cold cache and warm cache results are separate. Report initial indexing elapsed time, counts and
peak CPU/memory separately; index completion must not be a dependency of app search.

A target miss opens a performance issue with the slow segment. Changing a target requires a recorded
product tradeoff and updated specification; do not relax a budget silently to turn a run green.

## 5. Visual and release evidence

Create original review captures for the states in product-spec.md section 6. Each capture records
theme, locale, text scale, viewport/work area, runtime, and source identity. Check the actual native
transparent window over bright and dark backgrounds. A browser screenshot is insufficient for blur,
corners, focus, Accessibility, input methods, and window positioning.

An evidence record uses: `QA ID | milestone | platform/build | fixture | expected | actual |
status (Not run/Pass/Fail/Blocked) | artifact path | remaining gap`.
For an uncommitted tree, record an aggregate source SHA-256 of tracked and untracked source/config
files used to build, excluding generated assets, caches, dependencies and secrets. A Git commit
alone does not identify this currently untracked working tree. Artifact names/paths are generated
when evidence exists; do not create links to imagined screenshots or measurements.

M3 exit: all applicable QA cases and budgets pass, five-day dogfood criteria pass, visual review is
recorded, no Critical/High defects remain, and the support matrix lists the exact tested OS/build.
Signing, updater verification and distribution require a separate release work package; this plan
does not authorize publishing. Never start/restart/stop a dev server as a verification shortcut.
