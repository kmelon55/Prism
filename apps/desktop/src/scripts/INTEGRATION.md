# Script execution integration

The script panel adds explicit argument entry, cancellable foreground execution, live bounded stdout/stderr, and terminal success/failure/cancelled/timedOut/interrupted states. Discovery and panel mount never execute scripts.

## Root integration

1. Initialize `ScriptCommandRegistry` from the native app-data path during setup as described in [script durability](../../../../docs/script-durability.md). Register `script_commands::list_script_command_runs`, `script_commands::start_script_command`, `script_commands::get_script_command_run`, and `script_commands::cancel_script_command` in `lib.rs` alongside the existing commands. The existing `ScriptCommandRegistry` state owns run records; no Cargo changes or additional managed state are necessary.
2. Resolve launcher selections with `await getScriptCommandForItem(item)` from `providers/scripts.ts`, then display `<ScriptRunPanel script={script} onBack={...} />` from `scripts/ScriptRunPanel.tsx`.
3. For explicit one-Enter execution of zero-argument commands, call `void startScriptSession(script.id, [])` from `scripts/runStore.ts` in the launcher action handler, after resolving the script and before displaying the panel. The store rejects overlapping starts for the same script. Scripts with argument metadata open their form first. If the root only opens the panel, label that action `Open script` rather than `Run script`.
4. Disable palette keyboard handling while the panel is open. Back returns to the palette without cancelling; users cancel only with the panel Cancel button. Keep input focus and the Back button reachable.
5. Style hooks: `script-run-panel`, `script-run-header`, `script-run-form`, `script-argument`, `script-run-actions`, `script-run-status[data-state]`, `script-run-error`, and `script-run-output`. The output sections use `pre[tabindex=0]`; constrain height, allow scrolling, and wrap long lines. User metadata/output remains literal text.

The legacy `run_script_command` and provider functions remain available. Required argument metadata makes argument-free legacy invocation fail validation; new executions should use the run-session API.

## Native contracts

- `start_script_command({scriptId, args}) -> ScriptRunSnapshot`
- `get_script_command_run({runId}) -> ScriptRunSnapshot`
- `cancel_script_command({runId}) -> ScriptRunSnapshot`

A snapshot includes `runId`, `state` (`running | success | failure | cancelled | timedOut | interrupted`), `result`, `error`, `stdout`, `stderr`, `stdoutTruncated`, and `stderrTruncated`. Terminal `result` preserves the previous run-result shape and adds `cancelled`. Cancel requests may return `running` while the worker kills/reaps its process group; only terminal native state marks cancellation complete.

Runs retain 64 KiB per stream, default to a 10-second timeout configurable with `# prism:timeout=120` (1–3,600 seconds), and allow at most four active runs. Native and frontend caches retain at most 32 records and evict completed runs first. Native app-data checkpoints preserve summaries/output across restarts; unfinished runs become interrupted and never resume or rerun automatically. Renderer reloads reattach to running sessions in the same native process. Password arguments are never saved; password-script output is omitted from durable history. See [script durability](../../../../docs/script-durability.md) for initialization, limits, persistence failure behavior, and locale additions.

## Metadata

Existing `# prism:name=`, `description`, and `keywords` remain supported. The parser also accepts `# @raycast.title ...` and numbered `# @raycast.argument1 {...}` through `argument3`; native Prism syntax is `# prism:argument1={...}`. Metadata is bounded by the existing first 8 KiB / 64 lines.

```sh
#!/bin/sh
# prism:name=Search example
# prism:argument1={"type":"text","placeholder":"Search terms","percentEncoded":true}
# prism:argument2={"type":"dropdown","placeholder":"Scope","optional":true,"data":[{"title":"All","value":"all"}]}
printf '%s\n' "$1" "$2"
```

Supported types are text, password, and dropdown; `optional` defaults false and `percentEncoded` defaults false. Numbering must be contiguous from 1 with at most three arguments. Empty optional values still occupy their positional argv slot. Values pass as process argv without shell interpolation; the native side enforces required values, dropdown membership, at most 8192 bytes per argument, and no NUL bytes. Invalid, duplicated, unsupported, or gapped argument metadata blocks execution and is exposed in `argumentError`. Password drafts clear after submission and are not restored for retry.

Behavioral reference independently inspected: [Raycast argument documentation](https://github.com/raycast/script-commands/blob/master/documentation/ARGUMENTS.md) and [script command overview](https://github.com/raycast/script-commands/blob/master/README.md). This implements argument conventions only; Raycast output modes, refresh scheduling, icon packages, and other metadata are not claimed as supported. Prism retains its explicit foreground output panel and timeout.

## Localization additions for root

All product copy uses the existing `t()`. Add missing pairs to shared `locales/messages.json`; this worker did not edit it. User-owned script titles, placeholders, dropdown labels, stdout, and stderr must remain untranslated.

| English key | Korean value |
| --- | --- |
| Back | 뒤로 |
| Cancelling… | 취소 중… |
| Choose an option | 옵션 선택 |
| Exit code {0} | 종료 코드 {0} |
| Invalid script argument metadata. Fix the script and refresh commands. | 스크립트 인수 메타데이터가 올바르지 않습니다. 스크립트를 수정하고 명령을 새로고침하세요. |
| No output yet. | 아직 출력이 없습니다. |
| Optional | 선택 사항 |
| Output truncated at 64 KiB. | 출력은 최대 64 KiB까지 표시됩니다. |
| Ready to run | 실행 준비됨 |
| Retry status check | 상태 확인 다시 시도 |
| Run again | 다시 실행 |
| Running | 실행 중 |
| Script cancelled | 스크립트 취소됨 |
| Script command | 스크립트 명령 |
| Script failed | 스크립트 실행 실패 |
| Script succeeded | 스크립트 실행 성공 |
| Standard error | 오류 출력 |
| Standard output | 표준 출력 |
| Starting script… | 스크립트 시작 중… |
| You can go back while the script runs. | 스크립트가 실행되는 동안 뒤로 돌아갈 수 있습니다. |
| {0} ms | {0} ms |

Additional new native/API error keys (the panel passes product errors through `t()`):

| English key | Korean value |
| --- | --- |
| Script run is unavailable. | 스크립트 실행 상태를 사용할 수 없습니다. |
| Invalid script run identifier. | 스크립트 실행 식별자가 올바르지 않습니다. |
| Script runs are unavailable. | 스크립트 실행 상태를 사용할 수 없습니다. |
| Script run is no longer available. | 스크립트 실행 기록이 더 이상 없습니다. |
| At most four script commands can run at once. | 스크립트는 한 번에 최대 4개까지 실행할 수 있습니다. |
| Script run identifiers exhausted. | 스크립트 실행 식별자를 더 이상 만들 수 없습니다. |
| Could not start script worker: {0} | 스크립트 실행을 시작하지 못했습니다: {0} |
| Too many script arguments. | 스크립트 인수가 너무 많습니다. |
| Argument {0} is invalid or too long. | 인수 {0}이 올바르지 않거나 너무 깁니다. |
| Argument {0} is required. | 인수 {0}은 필수입니다. |
| Argument {0} must be one of the listed choices. | 인수 {0}은 목록에 있는 옵션이어야 합니다. |
| Duplicate script argument metadata. | 스크립트 인수 메타데이터가 중복되었습니다. |
| Invalid script argument metadata. | 스크립트 인수 메타데이터가 올바르지 않습니다. |
| Script arguments must be numbered consecutively from 1. | 스크립트 인수는 1부터 순서대로 지정해야 합니다. |
| Invalid script command. | 스크립트 명령이 올바르지 않습니다. |

## Validation

See [script durability](../../../../docs/script-durability.md#validation) for current test commands, coverage, and verification boundaries. The script worker owns isolated native fixture tests and frontend session/panel tests; the coordinator owns the serialized full Rust check and packaged-app verification.
