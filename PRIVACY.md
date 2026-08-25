# Privacy

[中文](PRIVACY.zh-CN.md)

Wrist Remote is self-hosted software. The project maintainers do not operate a relay, analytics service, advertising service, or user account system for this repository.

## Data handled locally

Depending on enabled features, the Apple apps and Mac bridge may process button actions, app selections, microphone recordings, speech transcripts, task status, summaries, and confirmed replies. Client credentials, pairing state, and end-to-end encryption keys are stored in Apple Keychain. Local preferences remain within the app containers or application-support directory.

Microphone audio is captured only after an explicit Watch interaction. General dictation is inserted into the current foreground app as soon as final recognition succeeds. To perform that insertion, the bridge briefly writes the transcript to the macOS general clipboard, simulates paste, and conditionally restores the previous clipboard value after roughly 450 milliseconds. Other software running as the same user may observe the temporary value, and a concurrent clipboard change may prevent restoration. Codex task speech follows a different path: it remains a draft until the user confirms submission.

## Optional relay

Internet mode is disabled until a developer deploys and provisions their own Cloudflare Worker. Application payloads are end-to-end encrypted between the Apple device and Mac. Cloudflare's Worker secret store holds the allowed room ID and bootstrap Mac bearer; Durable Object SQLite holds token hashes, a generated relay-device UUID, initialization time, and replay/rate-limit state. The relay does not persist ciphertext or provide an offline queue.

Cloudflare terminates HTTPS and can observe Bearer headers. Cloudflare and network providers can also observe metadata such as IP addresses, timing, request sizes, request frequency, and room paths. Operators are responsible for their own Cloudflare configuration, retention settings, jurisdiction, and privacy obligations.

## Codex integration

The optional local hook processes task metadata delivered on loopback. The Watch receives the thread and turn identifiers, canonical working directory, a normalized prompt title of up to 72 characters, and a completed-task summary of up to 160 characters. A completion notification uses the summary or title as its body and stores thread, turn, and revision identifiers in notification metadata. Depending on Apple Watch notification-preview settings, that text may appear on the lock screen or in Notification Center. Disable notification previews or Wrist Remote notifications if task text is sensitive. Confirmed replies are submitted through the locally installed Codex CLI. Users are responsible for the privacy policies and retention behavior of services they choose to connect.

## Diagnostics

The repository does not collect telemetry. Diagnostic output remains local unless a user chooses to share it. Before sharing a report, remove credentials, identifiers, paths, transcripts, screenshots, logs, and provisioning data.

## Deletion

Removing the apps does not necessarily remove Keychain entries. Users who want complete deletion should remove the app containers, application-support data, and Wrist Remote Keychain entries from their own devices. Relay operators should also delete their Worker, Durable Object namespace, and secrets.
