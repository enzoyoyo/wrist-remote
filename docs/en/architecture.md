# Architecture

[简体中文](../zh-CN/architecture.md)

Wrist Remote separates interaction, configuration, and action execution. The checked-in personal build is private-only: LAN is preferred, Tailscale is an optional private candidate, and the public relay is disabled by both build metadata and endpoint configuration.

## Data flow

```text
Apple Watch
  ├─ foreground LAN buttons: encrypted HTTP :60929 → Mac Bridge
  ├─ LAN relay and voice: WatchConnectivity → iPhone → encrypted TCP :60927 → Mac Bridge
  └─ private WAN: WatchConnectivity → iPhone → Tailscale TCP → Mac Bridge

Codex hook producer → authenticated loopback HTTP :60928 → Mac Bridge
Codex voice: Mac Bridge → Codex online transcription → text → local app-server stdin/stdout → selected task
```

The Mac does not expose a public inbound port. The private-only build also refuses public relay provisioning or requests. Tailscale Funnel, router port forwarding, public proxies, and public wildcard listeners are outside the supported architecture.

## Responsibilities

### Watch

- Presents 12 virtual buttons, favorites, task state, recent-conversation selection, independent-task creation, and original-audio input.
- Resolves single, double, and long presses locally so WAN latency cannot change gesture meaning.
- Emits semantic haptics on commit. Reduce Motion affects visual animation, not haptic intent.
- Uses an independently paired foreground LAN connection for direct buttons, or the paired iPhone through WatchConnectivity. Voice still uses the iPhone relay.

### iPhone

- Stores and edits the shared Watch/iPhone action profile and presents a 12-button phone remote.
- Every profile contains all 12 buttons and all three gestures per button.
- Discovers Bonjour, manages LAN/Tailscale direct candidates, completes pairing, and relays Watch actions and Codex conversation requests to the Mac.

### Mac bridge

- Binds `_wristremote._tcp` on port `60927` to one concrete RFC1918 IPv4, IPv4 link-local, or IPv6 ULA address on an approved non-tunnel local interface. No safe address means no listener.
- Binds the Watch HTTP endpoint `/v1/bridge` on port `60929` to a concrete LAN address; application messages are authenticated and encrypted, not plaintext commands.
- Validates LAN source address, protocol role, capabilities, and profile revision.
- Performs a bounded action set through Accessibility; it is not a general remote shell.
- Uses the system Speech framework only for foreground dictation.
- Writes Codex PCM to a Bridge-owned, owner-only WAV, uses the signed-in Codex account for first-party online transcription, then queues text to the selected task through local app-server.
- Exposes the authenticated Codex hook only on `127.0.0.1:60928`.
- In a private-only build, revokes historical relay provisioning and does not initiate public-relay traffic.

### Dormant relay source

- Relay source remains available for separately reviewed variants.
- The tracked build sets `WRISTREMOTE_PRIVATE_ONLY = YES`; the reserved `.invalid` URL is an independent second gate.
- The private-only Apple apps and Bridge reject relay provisioning and requests even if old credentials remain in Keychain, then propagate a revocation tombstone.
- Public-relay code is not a runtime fallback for LAN or Tailscale in this build.

## LAN secure session

Listener creation first restricts the local endpoint to a concrete, non-publicly-routable address on an approved non-tunnel local interface. The first session then uses Curve25519 key agreement. A P-256 installation identity signs the ephemeral session public key, and both sides display a six-digit code derived from the session key. After user approval, messages use ChaChaPoly authenticated encryption. An independent post-accept gate permits only loopback, link-local, private IPv4/IPv6, and same-physical-prefix IPv6 sources; it does not resolve hostnames to bypass source checks.

## Public-relay exclusion

The private-only build must satisfy both checks before any relay path can operate: `WRISTREMOTE_PRIVATE_ONLY` must be `NO`, and the configured HTTPS endpoint must be operational rather than `.invalid`. The checked-in values fail both checks. A separately reviewed relay build therefore requires a deliberate source-controlled build decision and a different endpoint; it cannot be enabled from the running app. Funnel, port forwarding, and public proxies are not supported substitutes.

## Route selection

For the iPhone route, LAN receives a 0.9-second head start. If it is not ready, the iPhone may race the explicitly configured Tailscale IP and adopts the first ready private route. An active gesture or voice stream remains pinned to one route until completion. Failure never creates an offline action or audio queue; serialization or encryption alone is not execution or delivery success.

Foreground Watch buttons can instead use LAN HTTP `60929`, with an independent Watch identity and separate Mac approval. The authenticated iPhone passes only public endpoint/identity configuration to Watch, never its private key. This path requires the full profile revision to be acknowledged, correlates action receipts by request ID, rejects expired or duplicate requests, and stops polling in the background. It carries no voice and does not provide a Watch Tailscale route. See [Phone and Watch connections](phone-watch-connection.md).

## Profile consistency

Action profiles carry a revision. The Mac executes only after validating and installing the full target revision. Old revisions, missing buttons, and unsupported actions are rejected. Task state uses a separate monotonic state revision plus clear tombstones so an old completion summary cannot reappear after reconnect.

## Voice and task replies

The Watch sends bounded PCM packets through the live iPhone private route. For foreground dictation, the Mac Speech framework recognizes the audio and `BridgeTextInjector` immediately injects the result into the focused input. For Codex, the Mac writes 16 kHz mono PCM to a Bridge-owned temporary WAV (`0700` directory, `0600` file) and computes a digest. `CodexNativeVoiceTranscriber` sends that audio to the fixed first-party Codex online transcription endpoint using the signed-in account's in-memory app-server authentication. Redirects and disk HTTP caching are disabled. After revalidating the target, the Bridge queues the returned text through app-server stdin/stdout. This requires Internet access; private-only control does not mean offline transcription. Codex voice uses neither macOS Speech nor the pasteboard. Audio, paths, and transcripts do not enter Bridge logs or ledgers or process arguments; the temporary WAV is removed when the attempt finishes. Partial or cancelled captures are deleted; only Bridge-owned stale `watch-*.wav` files older than 24 hours are purged at startup.

Codex recording requires an exact existing target and a short-lived Mac lease. Selecting **New task** first performs an independent `thread/start` with no fork or parent, registers the returned thread as an existing target, and only then enables recording. During a continuous recording, each Watch packet advances only after the Mac acknowledges that exact sequence. A disconnect, timeout, or missing acknowledgement fails closed, discards the partial recording, and does not replay after reconnect.

`BridgeTextInjector` briefly writes the recognized text to the general system pasteboard and simulates Command-V. After approximately 450 ms, it restores the previous contents only if the pasteboard still contains that temporary text and has not changed. Other same-user processes may observe the text during this window. If another process changes the pasteboard, the bridge preserves the new contents instead of overwriting them, but the original contents may not be restored automatically.

## Interaction and cancellation ownership

The Watch home owns destination selection and original-audio capture. The remote deck is a separate navigation destination; opening a picker never opens a text field. The iPhone separates routine reconnection from explicit pairing deletion.

```text
idle → hold threshold → preparing → recording → finishing → awaiting receipt
         ↓                 ↓           ↓           ↓
       release           cancel      cancel      cancel
         ↓                 └───────────┴───────────┘
        idle                     discard → idle
```

Releasing after capture sends once; dragging away, leaving the scene, interruption or the duration limit discards the unfinished recording. Once the stop/submit request has left the Watch, cancellation cannot promise to retract it: the UI waits for a receipt and never retries automatically after an ambiguous result.

The Mac reserves a nonce-bound start ticket before asynchronous destination validation. Cancellation and stopping invalidate that ticket even before a microphone or WAV exists. Start completions, audio, stop and cancel remain bound to the initiating stream. A stale completion cannot claim a newer stream. Catalog capability renewal waits for capture and receipt handling to finish, renews only the same thread/workspace/epoch, and does not overwrite a delivery result or initiate background selection requests. Public-relay revocation cannot clear private-route receipt state.

Presentation is split into home, picker, voice control, draft and task-detail views. A pure press-state reducer owns finger contact and delayed recognition; a separate catalog-maintenance state covers cancellation before a receipt exists. Reduced Motion disables press-scale transitions; semantic haptics remain independently configurable.

The workspace identity registry is bounded to 128 aliases. Exhaustion rejects new identities without discarding existing identities or deleting worktrees; it is distinct from corruption. A retention/migration design must preserve canonical identity before raising or reclaiming this limit.

## Persistence

| Data | Location |
|---|---|
| Action mappings, favorites, layout | Apple app-owned containers |
| Pairing identities, pinned trust, private endpoint, hook token | Apple Keychain |
| Selected applications and HMAC-protected Codex idempotency ledger, with its random key in Keychain | Bridge preferences, Keychain, or Application Support |
| Active Codex original-audio WAV | Bridge-owned Application Support directory; `0600`, deleted after use/cancellation |

Tailscale remains an independent service and can observe its own account, control-plane, and transport metadata. See the repository-root `THREAT_MODEL.md` for the complete boundary.
