# Codex integration

[简体中文](../zh-CN/codex-integration.md)

Codex integration is an optional local feature. It sends the current task's running/completed state and a summary of up to 160 characters to the Watch, and lets the user confirm a voice reply for a completed task.

## Security boundary

- The hook binds only to `127.0.0.1:60928`; it is not reachable from LAN or the Internet.
- Every request requires a random 32-byte bearer token generated on first run.
- The token lives in bridge Keychain and is absent from repository and hook configuration.
- Headers are limited to 16 KiB and JSON bodies to 512 KiB. Chunked transfer is rejected.
- Only `POST /codex-hook` with `Content-Type: application/json` is accepted.
- A task reply must match the exact current thread, turn, working directory, and task revision, and that task must still be completed.
- Voice text requires user confirmation. The bridge never submits a draft automatically.

Hook events expose the thread/turn identifiers and full `cwd` to the bridge. The bridge derives a task title of up to 72 characters and a summary of up to 160 characters and synchronizes them to the Apple devices; with Internet relay enabled, these application payloads travel as E2E ciphertext. Do not place secrets in task titles, paths, or prompts if they should not appear on the Watch.

When a task completes, the Watch creates a local notification whose body contains the summary or title and whose metadata contains the thread, turn, and revision. Apple Watch may show that content on the lock screen or in Notification Center according to notification-preview settings. Disable previews or Wrist Remote notifications when task text is sensitive.

## Configure the hook

1. Complete the base installation and open the Mac bridge once so it creates the hook token.
2. Open `examples/codex-hooks.json`.
3. Replace its command placeholder with the actual absolute path to `scripts/codex-notify.sh` in this clone.
4. Merge the `UserPromptSubmit` and `Stop` entries into your Codex hook configuration. Do not replace unrelated hooks.
5. Restart or reload the Codex hook configuration.

The notification script accepts Codex JSON on stdin, reads the Bundle prefix from `Config/Local.xcconfig`, and retrieves the matching token from Keychain. It creates a temporary curl configuration with mode `0600` and deletes it on exit; the token is not placed in shell history.

## Event format

The bridge accepts these Codex hook fields:

| Field | Required | Constraint |
|---|---:|---|
| `session_id` | Yes | Non-empty, no whitespace, up to 128 characters; reply path requires a UUID |
| `turn_id` | Yes | Non-empty, no whitespace, up to 128 characters |
| `hook_event_name` | Yes | `UserPromptSubmit` or `Stop` |
| `cwd` | Yes | Actual absolute working directory at runtime, up to 4096 UTF-8 bytes |
| `prompt` | No | User prompt used for the running summary |
| `last_assistant_message` | No | Completion result used for the completed summary |

Do not commit hook samples containing real paths, task content, or identifiers.

Event semantics:

- `UserPromptSubmit` moves the task to running.
- `Stop` moves it to completed and prefers the last assistant message for its summary.
- The same session, turn, and event is an idempotent duplicate.
- A late UserPromptSubmit after completion is marked `ignoredOutOfOrder`.

## Current thread selection

The first valid hook pins its thread in the bridge. Events from other threads do not automatically take over the Watch home screen. To change tasks, click **Switch to next chat** in the Mac bridge, then wait for the target thread's next hook event. The button does not scan or read other chats by itself; the target becomes current only after that new hook arrives.

Successful response:

```json
{"accepted":true,"disposition":"accepted"}
```

A new event returns HTTP 202. A safely handled duplicate or out-of-order event returns 200. Invalid application data returns 422. HTTP parsing can also return 400, 401, 404, 405, 413, 415, or 431.

## Reply from the Watch

1. The Watch home shows current task state or completion summary.
2. Start Codex voice only for a completed task.
3. The Mac Speech framework creates a draft.
4. The user confirms the draft.
5. The bridge revalidates thread, turn, cwd, and revision against the exact current completed task.
6. The bridge invokes `codex queue --thread <thread-id> --message <confirmed-text>`.
7. The CLI must accept within five seconds. The bridge returns an explicit receipt and deduplicates the submission ID.

If the task changes during recording, the old recording and reply are rejected rather than sent to the new task.

## Codex executable

Leave `WRISTREMOTE_CODEX_EXECUTABLE_PATH` blank to let the bridge search safe candidate locations. If discovery fails, set the absolute path to your local Codex executable in ignored `Config/Local.xcconfig`, then rebuild the bridge.

Never commit a personal installation path.

## Known local risk

The current Codex CLI receives confirmed text in its `--message` process argument. Software running as the same macOS user with process-inspection capability may briefly observe that argument. This does not weaken relay E2E encryption, but it is a local endpoint risk. Do not submit passwords, tokens, or other secrets through this feature.

## Disable

Remove only the two Wrist Remote entries from your Codex hook configuration. Preserve unrelated hooks. Other remote and voice features do not depend on the Codex hook.
