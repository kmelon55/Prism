# Launcher research notes

Historical research log. For the current product direction, use [product-spec.md](product-spec.md).
The initial fixed-preview/spectral visual language below is superseded by its compact-list visual
contract. Historical capability exclusions describe their dated slices, not the current roadmap.

조사일: 2026-09-02

이 문서는 구조와 상호작용 원칙을 비교하기 위한 메모다. 아래 프로젝트의 코드, 자산,
브랜드, 화면을 Prism에 복제하지 않았다. Prism의 구현은 별도 타입과 시각 언어로 작성했다.

## 확인한 프로젝트

| 프로젝트 | 공식 자료와 확인한 특징 | 라이선스/사용 원칙 |
| --- | --- | --- |
| [Vicinae](https://vicinae.com/) | [공개 저장소](https://github.com/vicinaehq/vicinae)와 [확장 문서](https://docs.vicinae.com/extensions/getting-started)를 확인했다. C++/Qt 네이티브 런처 위에 React/TypeScript 확장, script command, 명확한 action/metadata 모델을 둔다. | 저장소는 GPL-3.0. 아이디어 수준에서 provider와 command를 분리하는 이유만 참고했으며 코드는 사용하지 않았다. |
| [SuperCmd](https://supercmd.sh/) | [공개 저장소](https://github.com/SuperCmdLabs/SuperCmd)는 Electron main/React renderer/native helper 경계를 두고 Raycast 호환 확장을 제공한다. 검색 가능한 command catalog, 별도 settings store, OS 기능을 위한 좁은 native helper가 핵심이다. | 공개 저장소는 MIT. Prism은 호환 shim이나 구현을 가져오지 않고, UI가 OS 명령을 직접 만들지 않는다는 경계만 반영했다. 공식 사이트의 현재 제품과 공개 저장소 세대는 달라질 수 있으므로 저장소에 공개된 구조만 근거로 삼았다. |
| [Look](https://github.com/kunkka19xx/look) | [architecture 문서](https://github.com/kunkka19xx/look/blob/main/docs/architecture.md)와 [user guide](https://github.com/kunkka19xx/look/blob/main/docs/user-guide.md)를 확인했다. 키보드 우선, local-first 검색, Rust 검색 코어와 작은 FFI/Tauri 경계, 플랫폼별 shortcut 치환이 특징이다. | 저장소는 GPL-3.0. 코드와 검색 알고리즘을 가져오지 않았다. Prism MVP에서는 플랫폼 독립 command 계약과 최소 Rust adapter만 만들었다. |
| [Raycast](https://www.raycast.com/) | [공식 UI API](https://developers.raycast.com/api-reference/user-interface), [Action Panel API](https://developers.raycast.com/api-reference/user-interface/action-panel), [설정 문서](https://manual.raycast.com/settings), [공개 extension 저장소](https://github.com/raycast/extensions)를 확인했다. 선언적 List/Detail과 primary action, `Cmd/Ctrl+K` action discovery, command에서 설정으로 가는 경로가 강점이다. | 공개 extension 저장소는 MIT지만 Raycast 제품 전체의 코드가 공개된 것은 아니다. Prism은 목록+preview+action이라는 정보 구조만 참고하고, 화면 구성·토큰·컴포넌트·브랜드는 독자적으로 작성했다. |
| [Asyar](https://asyar.org/) | 사용자가 언급한 대상은 [Xoshbin/asyar](https://github.com/Xoshbin/asyar)로 식별했다. 공식 사이트와 저장소가 모두 macOS/Windows/Linux용 Rust/Tauri 런처를 가리킨다. manifest 권한, iframe 격리, frontend와 Rust 양쪽 permission gate, root-search action을 설명한다. | 현재 저장소의 `LICENSE`와 GitHub SPDX 표시는 GPL-3.0이지만 README는 AGPLv3라고 서술해 서로 일치하지 않는다. 따라서 정확한 재사용 조건을 임의로 해석하지 않고 강한 copyleft 자료로 취급해 코드나 스키마를 사용하지 않았다. |

## Prism에 반영한 결정

- 검색 대상은 `CommandItem`, 행동은 `CommandAction`, 공급원은 `CommandProvider`로 분리했다.
  UI는 provider의 OS 접근 방식을 알지 못한다.
- 모든 provider는 `AbortSignal`을 받고 독립적으로 실패한다. 한 공급원의 실패는 나머지 결과를
  버리지 않으며 실패 상태를 검색면 안에 표시한다.
- `Enter`는 primary action, `Cmd/Ctrl+K`는 선택 항목의 action panel, `Escape`는 현재 깊이에서
  뒤로 가는 일관된 keyboard path로 잡았다.
- 목록과 preview는 한 화면에 두되, Raycast 화면을 복제하지 않았다. 왼쪽의 고밀도 검색면과
  오른쪽의 고정된 focus plane, 선택에만 나타나는 얇은 spectral edge가 Prism의 언어다.
- 경쟁 제품의 현재 화면에서 공통적으로 확인되는 floating launcher의 장점은 가져오되 화면을
  복제하지 않았다. 바깥 webview를 투명하게 만들고 하나의 rounded translucent surface 안에
  낮은 대비의 panel을 중첩했다. spectral glow는 shell 배경, 선택 edge, preview 전환에만 제한해
  검색 정보보다 앞에 나오지 않게 했다.
- 네이티브 앱 탐색과 실행은 Rust가 소유한다. React는 typed IPC를 호출할 뿐 shell command를
  조합하지 않는다. 실행 전 Rust가 경로를 앱 catalog root 아래로 다시 제한한다.
- 설정은 command search와 shortcut에서 모두 진입할 수 있다. 사용자 preference는 local webview
  storage에 두고, native application index와 icon cache 유지보수는 좁은 Tauri command로 분리한다.
- 향후 확장은 Raycast 호환을 기본 목표로 삼지 않는다. 별도 프로세스/격리 surface와 선언적
  capability, Rust 측 재검증이 갖춰지기 전에는 임의 third-party code를 실행하지 않는다.

## 최초 shell에서 의도적으로 반영하지 않은 것

- clipboard history, AI agent, file index, window management, background daemon, extension store
- sync, 파일 전송, 미러링, KDE Connect식 상시 연결
- 다른 제품의 아이콘, 테마, 레이아웃, API 호환 layer

## 2026-09-03 performance follow-up

The first native-icon implementation coupled application discovery to synchronous icon extraction.
That made every cold search wait for every installed application's full-size artwork. A focused
source review found the same separation in mature launchers:

- [SuperCmd keeps command data and per-application icon caches separate](https://github.com/SuperCmdLabs/SuperCmd/blob/2da7b9e5dec0199a972a59cece402c85f729d5d7/src/main/commands.ts#L106-L215),
  returns stale catalog data immediately, and refreshes it in the background. Prism adopted the
  cache separation, but retained its direct AppKit integration instead of copying SuperCmd's helper
  process strategy.
- [Look documents why uncached `NSWorkspace.icon(forFile:)` calls in a row body cause flicker](https://github.com/kunkka19xx/look/blob/4b9821e63dedc883b65d2b45f58ca08e6988f571/apps/macos/LauncherApp/look-app/Support/RowIconCache.swift#L4-L34)
  and uses a 256-entry `NSCache`. Prism uses the same bounded-capacity principle with an independent
  Rust LRU implementation.
- [Vicinae limits image decoding to a dedicated pool](https://github.com/vicinaehq/vicinae/blob/9ab901dc96684c564f64660949730d26e5e144cc/src/server/src/ui/image/image-renderer.cpp#L35-L44)
  and [renders macOS file icons at the requested target size](https://github.com/vicinaehq/vicinae/blob/9ab901dc96684c564f64660949730d26e5e144cc/src/server/src/ui/image/mac-file-icon-loader.mm#L7-L66).
  Prism similarly bounds native icon concurrency and sends a 128-by-128 PNG rather than a
  1024-by-1024 source representation across IPC.
- [Asyar debounces application-index changes and avoids access-only watcher loops](https://github.com/Xoshbin/asyar/blob/d11756dc982f782effcd142129e50162284ce495/asyar-launcher/src-tauri/src/application/index_watcher.rs#L1-L160).
  Prism now watches only create/modify/remove events, coalesces bursts for 500 ms, and refreshes its
  independently implemented catalog in a background thread.

The resulting boundary is: metadata is search-critical, artwork is optional presentation data, and
maintenance controls are explicit. Preferences now include an application-icon toggle, application
index refresh, and icon-cache clearing. No source code, visual assets, or branded UI from the reviewed
projects was copied.

## 2026-09-03 native search and execution follow-up

The native application provider previously fetched the complete catalog into React and ran the shared
TypeScript ranker again on every query. The revised path keeps a persisted catalog and pre-normalized
search fields inside the Rust process, bounds IPC output, and stores only successful-launch usage. This
follows the architectural lesson from Asyar and Look that search-critical native state belongs close to
the native index; Prism's database schema, match scoring, frecency formula, command names, watcher, and
frontend integration were written independently.

The future app store, background worker, and AI surfaces are deliberately not enabled by this change.
Asyar's separation of manifest permissions, isolated view/worker contexts, and host-owned caller
identity is the relevant safety model. Prism will first define its own manifest and capability broker;
third-party code will not receive arbitrary Tauri invoke access, native secrets, or the host DOM merely
because a package was installed.

## 2026-09-03 command management and shortcut follow-up

Prism now declares built-in commands in one immutable catalog with stable IDs and management metadata.
Preferences is a non-disableable recovery command; appearance, hide, and native maintenance commands may
be hidden locally without deleting their definitions. This follows the catalog boundary visible in
[Look's command definitions](https://github.com/kunkka19xx/look/blob/4b9821e63dedc883b65d2b45f58ca08e6988f571/apps/macos/LauncherApp/look-app/Support/AppConstants.swift#L575-L608)
and the separation of catalog data from runtime work in
[SuperCmd's command manager](https://github.com/SuperCmdLabs/SuperCmd/blob/2da7b9e5dec0199a972a59cece402c85f729d5d7/src/main/commands.ts#L70-L120),
without copying either implementation.

The editable global shortcut is owned by a narrow Rust manager and persisted only after a candidate
registration succeeds. A registration conflict returns the still-active setting to React. If startup
registration fails entirely, Prism keeps a visible taskbar or Dock recovery window instead of becoming
unreachable. Command visibility remains a validated local webview preference; native shortcut state stays
in a versioned native file so future extension settings cannot silently gain global-hotkey authority.

## 2026-09-03 native utilities and settings follow-up

The next slice adds a separate settings window, user search aliases, persisted per-command global
shortcuts, opt-in clipboard history, and allowlisted window actions. The architectural comparison was
refreshed against the public repositories rather than copying product UI or implementation code:

- [SuperCmd separates renderer commands from native clipboard and window helpers](https://github.com/SuperCmdLabs/SuperCmd),
  reinforcing that React should request typed capabilities rather than assemble OS automation itself.
- [Vicinae exposes clipboard history and a window switcher from a native launcher core](https://github.com/vicinaehq/vicinae),
  while keeping extensions behind a distinct contract.
- [Asyar documents layered clipboard privacy and cross-platform window support](https://github.com/Xoshbin/asyar).
  Prism does not yet claim equivalent concealed-item, source-application, encryption, or cross-platform
  coverage, so its clipboard history is default-off and memory-only and its window adapter is macOS-only.
- [Look keeps a local-first launcher surface with explicit shortcut mappings](https://github.com/kunkka19xx/look),
  supporting the decision to keep command metadata and shortcut registration outside the React view.

The palette now seeds built-in commands before asynchronous native providers settle, keeps resolved icon
success and failure states in a bounded renderer LRU across row remounts, and anchors the launcher on the
current monitor's upper third. The macOS path selects the screen directly in AppKit coordinates, avoiding
the cursor-to-monitor conversion mismatch in the cross-platform wrapper. These changes are independently
implemented under Prism's own provider and IPC contracts.

## 2026-09-04 Asyar clean-room capability review

The capability review used Asyar at pinned commit
[`d11756dc`](https://github.com/Xoshbin/asyar/tree/d11756dc982f782effcd142129e50162284ce495)
as behavioral research only. Asyar is GPL-3.0-only; Prism did not copy its source, schemas, strings,
tests, UI, assets, or command metadata. The implementation was designed against Prism's existing
provider and typed Tauri boundaries, with public platform documentation used for OS-facing contracts.

This slice adds independently implemented, bounded capabilities:

- allowlisted System Settings pages and the non-destructive Lock Screen action;
- a pure, resource-bounded arithmetic evaluator and one transient calculator result;
- explicit HTTP(S) opening and `web <query>` search with native URL validation;
- opt-in local Script Commands discovered from user-configured folders and executed by opaque registry ID;
- one-step restoration of the previous bounds for a window changed by Prism; and
- aliases, global hotkeys, and visibility controls for indexed installed applications.

AI agents, third-party extensions, browser companions, browsing-history access, background scripts,
schedules, sync, and credential-bearing browser automation remain separate milestones. They need their
own permission, provenance, credential-storage, cancellation, and process-isolation designs rather than
being inferred from a broad reference product.

## 2026-09-06 product planning reference snapshot

The user requested Asyar-informed independent implementation and the everyday completeness of
Raycast's basic features. This review used public product documentation and Prism's current source;
it did not run either reference app or measure their performance. No reference source, tests, schemas,
assets, UI markup, or benchmark scripts were incorporated into Prism in this task.

Asyar repository reference: `e0238045b0f03381124b0ec9727ee2f5d800cea8`, resolved from the GitHub API on
2026-09-06. The [LICENSE at that revision](https://github.com/Xoshbin/asyar/blob/e0238045b0f03381124b0ec9727ee2f5d800cea8/LICENSE)
contains GNU GPL version 3. Public website docs below are dated observations and are not asserted to
be built from that exact repository revision. The project constraint remains independent authorship;
this is not a general legal conclusion that GPL software cannot be reused under its terms.

| Official source inspected | Behavioral observation | Independent Prism decision |
| --- | --- | --- |
| [Asyar product overview](https://asyar.org/) | Describes apps, clipboard, snippets, calculation, URL destinations, layouts, shortcuts and specialized contexts | Track usable workflows and their depth, not just a command count |
| [Asyar system overview](https://asyar.org/docs/explanation/system-overview) | Distinguishes privileged built-ins from isolated extensions around a host | Preserve Prism's own native authority; defer third-party runtime work until desktop basics pass |
| [Asyar clipboard privacy](https://asyar.org/docs/explanation/clipboard-privacy) | Documents capture exclusions, pattern detection and protected local storage | Specify independently implemented exclusion, retention and key-unavailable behavior before persistence |
| [Asyar file search architecture](https://asyar.org/docs/explanation/file-search) | Treats file search as a dedicated indexing/query subsystem | Give Prism file search a bounded provider and explicit roots; do not copy schemas or ranking |
| [Raycast search](https://manual.raycast.com/search-bar), [actions](https://manual.raycast.com/action-panel), [aliases/hotkeys](https://manual.raycast.com/command-aliases-and-hotkeys) | Documents root search, contextual actions and personalization | Define exact alias precedence, stable selection, favorites and searchable actions as Prism contracts |
| [Raycast clipboard](https://manual.raycast.com/clipboard-history), [windows](https://manual.raycast.com/window-management) | Documents reuse/paste and focused-window operations beyond merely finding a command | Make target handoff, deletion, restore and display movement explicit acceptance cases |
| [Raycast files](https://manual.raycast.com/file-search), [quicklinks](https://manual.raycast.com/quicklinks), [snippets](https://manual.raycast.com/snippets) | Documents finding files, reusable destinations, and stored/expanded text | Include these missing workflows in M2/M3 with independent data and interaction models |
| [Raycast calculator](https://manual.raycast.com/calculator) | Documents conversions, dates and time zones as well as arithmetic | Include a bounded explicit conversion grammar; list live rates and broad natural language as remaining gaps |
| [Raycast scripts](https://manual.raycast.com/script-commands), [settings](https://manual.raycast.com/settings), [symbols](https://manual.raycast.com/emoji-symbols) | Documents personal automation, configuration access, and text-symbol workflows | Complete lifecycle/recovery and add an independently sourced local symbol picker |

Raycast's current manual also includes features beyond this selected baseline. M3 is deliberately
named selected desktop basics, not full Raycast parity. The product specification records omitted
capabilities so a small alpha cannot be described as having caught up. Reference examples and timing
claims were not adopted as acceptance fixtures; Prism's original fixtures and budgets are in
[quality-gates.md](quality-gates.md).

Deliverables from this planning review: [product specification](product-spec.md),
[sequenced implementation plan](delivery-plan.md), and [quality gates](quality-gates.md).
These establish intended behavior; screenshots, native execution and measurements remain Not run.
