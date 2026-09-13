# Privacy

[中文](PRIVACY.zh-CN.md)

Wrist Remote is self-hosted software. The project maintainers do not operate a relay, analytics service, advertising service, or user account system for this repository.

## Data handled locally

Depending on enabled features, the Apple apps and Mac bridge may process button actions, app selections, microphone recordings, foreground-dictation transcripts, Codex original-audio input, task status, summaries, and delivery outcomes. Client credentials, pairing state, the Mac and iPhone long-term P-256 installation identities, the iPhone's pinned Mac fingerprint, trusted iPhone fingerprints, and direct-session keys are stored in Apple Keychain. Local preferences remain within the app containers or application-support directory. Identity items are not silently replaced when unreadable or corrupt; connection fails until the storage is available or the user performs the applicable explicit recovery action.

Microphone audio is captured only after an explicit Watch interaction. Foreground dictation uses the Mac Speech framework and is inserted into the current foreground app as soon as final recognition succeeds. To perform that insertion, the bridge briefly writes the transcript to the macOS general clipboard, simulates paste, and conditionally restores the previous clipboard value after roughly 450 milliseconds. Other software running as the same user may observe the temporary value, and a concurrent clipboard change may prevent restoration.

Codex speech is a separate path and does not use macOS Speech recognition or the clipboard. The Watch sends bounded PCM packets over the live authenticated route. The Mac writes them to a temporary WAV inside a Bridge-owned directory with permissions `0700`; the file is set to `0600` and is limited to two minutes. Using the current Codex ChatGPT login, Bridge submits this audio to Codex's first-party transcription endpoint (`https://chatgpt.com/backend-api/transcribe`) and queues the returned text to the exact selected task. This requires internet access; it is not on-device transcription. The login token is obtained from the local app-server and kept only in memory; redirects and disk HTTP caches are disabled. Credentials, transcript, file path and audio bytes are excluded from logs and idempotency ledgers. Cancelled or disconnected captures are deleted, finalized recordings are deleted after transcription/submission returns, and Bridge startup removes only its own stale `watch-*.wav` files after 24 hours.

## Optional Tailscale private network

Private-network mode stores an enabled flag and the Mac's validated official Tailscale IP in the iPhone Keychain. In the private-only build, DNS names, URLs, ports, credentials, public IPs, and unrelated private IPs are rejected. Its only Tailscale-specific Mac preference is whether the independent listener is enabled. Separately from Tailscale configuration, the Mac Keychain stores its direct-protocol identity and trusted iPhone fingerprints, while the iPhone Keychain stores the pinned Mac fingerprint. Wrist Remote does not store Tailscale account credentials, authentication keys, tailnet policy, or Termius SSH credentials.

When enabled, action, audio, task, and reply payloads traverse the user's Tailscale network between the iPhone and Mac while remaining protected by Wrist Remote's mutually authenticated encrypted session. The six-digit code and a shortened Mac fingerprint are shown during first trust; the full fingerprints remain local in Keychain. Tailscale is an independent service with its own account, control plane, metadata, logs, retention, and privacy terms. Tailnet operators are responsible for those settings and for limiting access with Grants. The project does not use Tailscale Funnel and does not publish TCP `60927` to the public Internet.

The Apple Watch itself does not receive the Tailscale endpoint or join the tailnet. Live private-network commands pass through the paired iPhone using Watch Connectivity. A Watch that cannot reach its iPhone cannot use this path.

## Public relay and the private-only build

The checked-in personal build sets `WRISTREMOTE_PRIVATE_ONLY = YES` and keeps the relay URL at the reserved `.invalid` endpoint. Both gates must permit relay operation, so changing only one does not enable a public path. Historical relay provisioning is revoked rather than restored. Relay source remains for separately reviewed build variants, but the private-only build sends no command, audio, task, or Codex traffic through Cloudflare.

Do not substitute Tailscale Funnel, router port forwarding, a public proxy, or a public wildcard listener. Those mechanisms would create a different privacy and threat boundary and are unsupported.

## Codex integration

The optional local hook processes task metadata only on loopback. A Watch task card may receive thread and turn identifiers, a workspace display label rather than the canonical local path, a title of up to 72 characters, and a summary of up to 160 characters. The conversation picker may receive recent conversation titles, workspace labels, epoch-scoped random identifiers, and short-lived authorization leases. Canonical workspace paths remain on the Mac.

Codex completion notifications use generic text and contain no task title, summary, thread, or turn metadata. Voice delivery outcomes travel only in live replies and are excluded from durable Watch Connectivity application context. Selecting **New task** first creates an independent thread through local `thread/start`; no fork or parent identifier is supplied, and recording is unavailable until the returned thread has been registered as an existing target. After native transcription, text is queued over local app-server stdin/stdout, never process arguments. A queue receipt means queued, not task completion. The selected destination is revalidated after transcription; cancellation or a changed target does not trigger a fallback task or automatic resend. Watch-to-Mac selection and submission use Watch Connectivity plus the LAN/Tailscale private route, not a public relay; the separate Mac-to-Codex transcription request uses the first-party internet endpoint above. Users remain responsible for the privacy and retention behavior of services reached by their local Codex installation.

## Diagnostics

The repository does not collect telemetry. Diagnostic output remains local unless a user chooses to share it. Before sharing a report, remove credentials, identifiers, paths, transcripts, audio, screenshots, logs, provisioning data, Tailscale addresses, tailnet account selectors, and policy exports.

## Deletion

Removing the apps does not necessarily remove Keychain entries. Users who want complete deletion should remove the app containers, application-support data, and Wrist Remote Keychain entries—including installation keys and trusted fingerprints—from their own devices. **Forget trusted Mac** removes only the iPhone's pinned Mac fingerprint. **Reset this iPhone's pairing identity** replaces only the iPhone client identity and makes the Mac require a new approval; neither action is complete deletion or changes mappings or another remote. Tailscale membership and account data must be removed separately through Tailscale. Operators of a separately reviewed Relay-capable variant must additionally delete its Worker, Durable Object namespace, and secrets.
