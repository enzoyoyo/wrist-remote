# Codex integration

[简体中文](../zh-CN/codex-integration.md)

Codex integration is optional. The Watch home screen can show the current Codex task and its completion summary, select an exact destination from recent conversations, or create an independent task in a Mac-authorized workspace. Held speech uses Codex's first-party online transcription service, then local app-server queues text to that exact task; macOS Speech and the clipboard are not used.

## Watch workflow

1. Keep the Mac bridge, paired iPhone, and Watch app reachable.
2. Tap **Send to** on the Watch home screen. The app requests a fresh conversation catalog when it opens; pull to refresh or use the refresh button to retry.
3. Choose **Blank task** under **New conversation** for a task unrelated to previous projects, or **New in project** to keep using project files. **Recent** continues an existing conversation. The Watch cannot invent a thread or working directory.
4. Confirm **Create and select** to request an independent `thread/start` with no fork or parent. Blank tasks get a separate empty directory, without old project files, conversation history, or the launching task identity; global Codex settings still apply. Project tasks start without old chat messages but retain project files and rules. Wait for the new destination to be selected. Ambiguous creation is not automatically repeated.
5. Return home and hold the cyan voice control. Speak after the recording-start haptic, then release for Codex transcription and text submission to that exact existing task. Moving away cancels the recording. The latest result is visible on the home screen; queued is not completed.
6. Wait for the delivery outcome. A disconnect, missing packet acknowledgement, expired target, or app-server uncertainty fails closed and is not automatically replayed.

The target is frozen when recording begins. Catalog refreshes, task changes, and navigation cannot silently redirect the recording. An expired or mismatched target or connection lease is rejected; refresh and select again.

The **Current task** card and **Send to** serve different purposes: the card shows hook-synchronized task state, while the destination controls the conversation that receives speech. Remote buttons remain on a separate screen and selecting a Codex conversation never changes their mappings.

## Security and privacy boundary

- The hook binds only to `127.0.0.1:60928`; LAN, tailnet, and Internet peers cannot reach it.
- Every hook request requires a random 32-byte bearer generated on first run. It remains in bridge Keychain and is absent from repository and hook configuration.
- Headers are limited to 16 KiB and JSON bodies to 512 KiB. Chunked transfer is rejected. Only `POST /codex-hook` with `Content-Type: application/json` is accepted.
- Conversation listing, independent creation, and text submission use the local Codex `app-server` over `stdio://`, with no network listener. Audio uses the app-server's in-memory login token at the fixed first-party `/backend-api/transcribe` endpoint, with redirects and disk HTTP caches disabled. The destination is revalidated after transcription; text travels only over standard input, never process arguments. Failure does not create a fallback task or automatically resend. A queue receipt is not task completion.
- The Watch receives only sanitized titles, workspace display names, state, and short-lived opaque capabilities issued by the Mac. Full working directories remain inside the Mac bridge.
- The Mac allocates blank-task directories per request under Bridge-owned private storage. Project tasks can use only a workspace observed through recent threads or the current hook. The Watch cannot supply arbitrary paths. The Mac rejects returned directories, project associations, root-session identities, or history that violate the independent request.
- Target selection, independent task creation, recording, and submission bind exact operation IDs, target leases, stream/submission IDs, and audio digests. The Mac revalidates every stage and fails closed on expiry, replay, or mismatch.
- Each continuous-stream packet is acknowledged back to the Watch only after the Mac accepts that exact sequence. A connection break deletes the partial capture; reconnect never replays it automatically.
- The Mac stages Codex audio in a Bridge-owned `0700` directory as a `0600` WAV, limited to two minutes. The path and audio bytes do not enter logs or the idempotency ledger. The file is deleted after app-server returns, on cancellation/failure, or by scoped 24-hour stale cleanup.
- The durable idempotency ledger stores UUIDs, an HMAC fingerprint derived from the thread and audio digest, stage, thread ID, and queue receipt only. It stores neither audio, file paths, transcripts, nor working-directory paths.
- Completion notifications use the generic body “Task completed; open the app to view the result” and contain no summary, thread, turn, path, or revision metadata.

Codex conversation control is explicitly excluded from public Relay. The current personal build also requires `WRISTREMOTE_PRIVATE_ONLY = YES` and an `.invalid` Relay endpoint. Its path is Watch Connectivity to the paired iPhone, followed by the paired, mutually authenticated, encrypted direct channel to the Mac. A user-configured Tailscale private route may carry the iPhone-to-Mac leg when LAN is unavailable. If the Watch cannot reach its paired iPhone, this conversation-control path is unavailable and no operation is queued for later execution.

## Configure the hook

The hook synchronizes the **Current task** card and completion summary. Conversation selection and voice submission do not require placing Codex content in hook configuration.

1. Complete the base installation and open the Mac bridge once so it creates the hook token.
2. Open `examples/codex-hooks.json`.
3. Replace its command placeholder with the actual absolute path to `scripts/codex-notify.sh` in this clone.
4. Merge the `UserPromptSubmit` and `Stop` entries into your Codex hook configuration without replacing unrelated hooks.
5. Restart or reload the Codex hook configuration.

The notification script accepts Codex JSON on stdin, reads the Bundle prefix from `Config/Local.xcconfig`, and retrieves the matching token from Keychain. It creates a temporary curl configuration with mode `0600` and deletes it on exit; the token is never placed in shell history.

## Hook event format

The bridge accepts these fields:

| Field | Required | Constraint |
|---|---:|---|
| `session_id` | Yes | Non-empty, no whitespace, up to 128 characters; the compatibility reply path requires a UUID |
| `turn_id` | Yes | Non-empty, no whitespace, up to 128 characters |
| `hook_event_name` | Yes | `UserPromptSubmit` or `Stop` |
| `cwd` | Yes | Actual absolute working directory at runtime, up to 4096 UTF-8 bytes; the full value remains Mac-only |
| `prompt` | No | User prompt used for the running title |
| `last_assistant_message` | No | Completion result used for the completed summary |

Do not commit hook samples containing real paths, task content, or identifiers.

- `UserPromptSubmit` moves the task to running.
- `Stop` moves it to completed and prefers the last assistant message for its summary.
- The same session, turn, and event is an idempotent duplicate.
- A late `UserPromptSubmit` after completion is marked `ignoredOutOfOrder`.

The first valid hook pins that thread as the **Current task**. Events from other threads do not automatically replace the home card; this pin does not restrict the independent **Send to** selection.

## Catalog and workspaces

The bridge uses the local Codex `thread/list` method to read up to 12 recent conversations. The Watch picker displays up to 8 recent entries. Only a sanitized title, final workspace component, state, and short-lived capability cross devices.

**Blank task** does not require a recent thread or project. **New in project** lists workspaces observed through recent threads or the current hook. Git projects use a separate worktree; ordinary folders reuse the project directory. Neither project mode means an empty folder. If the blank entry is unavailable, update/check the Mac bridge and refresh the catalog.

## Codex executable

Leave `WRISTREMOTE_CODEX_EXECUTABLE_PATH` blank to let the bridge search safe candidate locations. If discovery fails, set the absolute path to the local Codex executable in ignored `Config/Local.xcconfig`, then rebuild the bridge.

Never commit a personal installation path. The bridge launches the fixed `app-server --listen stdio://` mode; messages and working directories travel as JSON over stdin and are not assembled into shell commands.

## Disconnect and recovery

- Opening the Watch app, activating Watch Connectivity, or restoring iPhone reachability triggers a status and catalog request.
- The iPhone restores the private LAN/Tailscale connection to the Mac. Identity mismatch remains blocked and is never silently re-trusted.
- A network failure does not automatically submit or replay audio. After recovery, refresh the catalog, verify the target, and record again deliberately.
- A Mac restart changes the server epoch, invalidating old targets. This is intentional protection against misdelivery.

## Disable

Remove only the two Wrist Remote entries from Codex hook configuration to stop task-state synchronization. Watch remote buttons, foreground dictation, and unrelated input-device configuration do not depend on the Codex hook. If conversation sending is not needed, simply do not select a target or record; the project never sends Codex content in the background.
