# Improve conversation requests and script recovery

## Behavior

AI Chat now owns request IDs, streamed text, pending questions, cancellation flags and errors per conversation. Switching or creating a conversation remains available while another reply runs; drafting and sending in another conversation does not replace the first request's state. Both the renderer and native request registry allow at most three simultaneous replies. A running conversation shows its existing compact sidebar status, and only that conversation's composer/model/edit controls are locked.

Every response captures its originating conversation and request ID. Background completions update and persist that conversation, while switching resolves the freshest destination snapshot after the outgoing draft save. Background errors and history-save errors remain associated with their conversation. Cancellation addresses only the selected request and preserves the question for explicit retry; retries reset cancellation state. A late provider success after cancellation cannot replace the cancelled draft. Unmount cancels every owned request and invalidates callbacks, and a renderer-wide history queue serializes writes/deletes/loads across component remounts.

Deletion policy is explicit: stop a conversation's running reply before deleting it. Other inactive conversations can be deleted while an unrelated reply runs. Confirmation, deletion-specific retry and tombstones remain in place; late callbacks and queued autosaves cannot resurrect deleted conversations. Existing forking, scroll following, keyboard switching, IME guards and per-conversation model settings remain covered by the existing component tests.

Script panels recover native snapshots before starting or displaying an execution. Registry lookup is read-only and deduplicated; failed recovery blocks starts and exposes an explicit status-check retry. Live runs resume polling, and completed runs restore their retained output. Opening a previously run command shows its result; the panel's explicit **Run again** action starts another execution. Password arguments are never retained for recovery. The native registry rejects duplicate concurrent starts of the same script, retains four simultaneous distinct scripts and at most 32 snapshots, and preserves opaque script IDs across refreshes for the same canonical registered path/root.

## Changed files owned by this worker

- `apps/desktop/src/AiChat.tsx`
- `apps/desktop/src/AiChat.test.tsx`
- `apps/desktop/src/ai/historyQueue.ts`
- `apps/desktop/src/scripts/runStore.ts`
- `apps/desktop/src/scripts/runStore.test.ts`
- `apps/desktop/src/scripts/ScriptRunPanel.tsx`
- `apps/desktop/src/scripts/ScriptRunPanel.test.tsx`
- `apps/desktop/src/providers/scripts.ts`
- `apps/desktop/src-tauri/src/ai.rs` (request registry only, plus its focused unit test)
- `apps/desktop/src-tauri/src/script_commands.rs`
- `docs/run-lifecycle-improvements.md`

The shared checkout initially contained the entire project as untracked files; no user files were staged or removed. The worker did not edit App.tsx, lib.rs, shared CSS, or locale dictionaries.

## Coordinator integration

Register `script_commands::list_script_command_runs` in the existing `tauri::generate_handler!` list. The coordinator has acknowledged adding this registration. No App hook is required: both `startScriptSession` and the panel perform recovery; only the panel passes `{ rerun: true }` for an explicit repeat execution.

Add these English/Korean dictionary pairs through the existing translation system:

| English key | Korean |
| --- | --- |
| Up to three conversations can reply at once. Wait for a reply or stop one. | 최대 세 대화에서 동시에 답변할 수 있습니다. 답변을 기다리거나 하나를 중지하세요. |
| Stop this reply before deleting the conversation. | 이 대화를 삭제하려면 먼저 답변을 중지하세요. |
| Restoring script run… | 스크립트 실행 상태를 복원하고 있습니다… |
| This script is already running. Restore its status before starting again. | 이 스크립트는 이미 실행 중입니다. 상태를 복원한 뒤 다시 실행하세요. |

## Validation

Worker-run checks:

- `pnpm --dir apps/desktop exec vitest run src/AiChat.test.tsx src/scripts/ScriptRunPanel.test.tsx src/scripts/runStore.test.ts`: **45 passed**.
- `pnpm --filter @prism/desktop typecheck`: passed after the final implementation changes.
- `rustfmt --edition 2021 apps/desktop/src-tauri/src/ai.rs apps/desktop/src-tauri/src/script_commands.rs`: passed.

New frontend tests cover background streaming and completion, isolated background save failure and explicit save retry, preserving another draft, three-request capacity, target-only cancellation, cancellation retry, inactive errors, deleting another inactive conversation while a reply runs, disabled running deletion, late deleted callbacks, destination completion during a queued outgoing save, stale mount callbacks, script reload reattachment, completion polling, deduplicated discovery, recovery failure, explicit observation retry, simultaneous start calls, target-only recovered cancellation, stale observation responses and explicit repeat execution.

Native tests requested from the coordinator, to run sequentially rather than concurrently with other workers:

```sh
cd apps/desktop/src-tauri
cargo test --lib script_commands::tests
cargo test --lib ai::tests::request_registry_bounds_concurrency_and_cancels_only_target
```

The new native tests are `run_listing_reattaches_after_refresh_without_execution_or_arguments` and `request_registry_bounds_concurrency_and_cancels_only_target`; the existing registry concurrency/cancellation test now uses distinct scripts to exercise the four-run bound. Fixtures run local disposable scripts only; no AI inference is involved.

## Boundaries

- Script execution remains bounded by the existing **10-second timeout** and **64 KiB per output stream**. No scheduler or configurable timeout was introduced.
- Script recovery lasts for the native process lifetime and its bounded registry; a full native app restart does not restore script processes or output. Removing and later re-adding a configured script identity is outside this recovery association.
- AI streams and interrupted partial replies remain in component memory while switching. Saved unanswered drafts and completed replies are durable; partial stream text is not written as a completed answer. Renderer reload cancels old AI requests rather than reattaching inference.
- Existing running Vite/Tauri processes and the user's app were never started, stopped or restarted. No process was manually controlled. The existing Tauri watcher can rebuild and relaunch automatically after native source edits; command availability in a particular running binary was not verified.
- Frontend validation uses mocked IPC. No paid AI calls, real-user scripts, browser/native interactive proof, commit, push, deployment or publishing occurred.
