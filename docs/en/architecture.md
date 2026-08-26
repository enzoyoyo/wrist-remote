# Architecture

[简体中文](../zh-CN/architecture.md)

Wrist Remote separates interaction, configuration, action execution, and public-network relay. The default path is LAN-only; Internet mode is an explicitly enabled self-hosted extension.

## Data flow

```text
Apple Watch
  ├─ LAN: WatchConnectivity → iPhone → encrypted TCP → Mac Bridge
  └─ WAN: E2E encrypted HTTPS → Cloudflare Worker / Durable Object
                                               ↓
                                       outbound WSS from Mac

Codex hook producer → authenticated loopback HTTP → Mac Bridge → local Codex CLI
```

The Mac does not expose a public inbound port. The relay is an Internet-accessible HTTPS endpoint, but the Watch, iPhone, and Mac remain clients or outbound connection initiators.

## Responsibilities

### Watch

- Presents 12 virtual buttons, favorites, task state, and voice entry.
- Resolves single, double, and long presses locally so WAN latency cannot change gesture meaning.
- Emits semantic haptics on commit. Reduce Motion affects visual animation, not haptic intent.
- Uses the iPhone LAN path through WatchConnectivity or, while active, the explicitly provisioned HTTPS relay.

### iPhone

- Stores and edits the Watch-owned action profile.
- Every profile contains all 12 buttons and all three gestures per button.
- Discovers Bonjour, completes pairing, establishes the encrypted LAN session, and transfers profiles and relay provisioning to the Watch.

### Mac bridge

- Binds `_wristremote._tcp` on port `60927` to one concrete RFC1918 IPv4, IPv4 link-local, or IPv6 ULA address on an approved non-tunnel local interface. No safe address means no listener.
- Validates LAN source address, protocol role, capabilities, and profile revision.
- Performs a bounded action set through Accessibility; it is not a general remote shell.
- Transcribes Watch audio with the system Speech framework.
- Exposes the authenticated Codex hook only on `127.0.0.1:60928`.
- Initiates an outbound WebSocket for relay operation.

### Cloudflare relay

- One deployment permits one private room; its Durable Object is routed deterministically from the room ID.
- Worker secret storage retains `ALLOWED_ROOM_ID` and `BOOTSTRAP_MAC_TOKEN`; the latter is the same value as the client-side Mac bearer.
- Cloudflare edge processing has access to request Bearer headers during authentication.
- Durable Object SQLite stores SHA-256 hashes of the Mac/device tokens, the randomly generated relay device UUID, initialization time, and replay, sequence, and rate-limit state.
- Memory holds only short-lived request correlation while waiting for the Mac; requests fail after 15 seconds.
- It does not decrypt application payloads, persist ciphertext, or provide an offline queue.

## LAN secure session

Listener creation first restricts the local endpoint to a concrete, non-publicly-routable address on an approved non-tunnel local interface. The first session then uses Curve25519 key agreement. A P-256 installation identity signs the ephemeral session public key, and both sides display a six-digit code derived from the session key. After user approval, messages use ChaChaPoly authenticated encryption. An independent post-accept gate permits only loopback, link-local, private IPv4/IPv6, and same-physical-prefix IPv6 sources; it does not resolve hostnames to bypass source checks.

## Internet session

Initial bridge provisioning creates independent room, device, device token, Mac token, and 32-byte E2E key values. The Mac and iPhone/Watch clients store the bearer and E2E credentials required for their roles in Apple Keychain; the E2E key is never sent to the relay. Cloudflare Worker secret storage separately retains the allowed room ID and a bootstrap token equal to the Mac bearer.

A Worker-secret disclosure exposes the room ID and Mac bearer. An attacker could impersonate the Mac at the relay authentication layer, occupy the connection, or cause denial of service. Without the client E2E key, however, the attacker still cannot decrypt application payloads. Bearer headers pass through Cloudflare edge processing; persisting token hashes instead of bearer plaintext in the Durable Object does not mean Cloudflare never handles bearer plaintext.

A device frame includes protocol version, operation ID, sender ID, monotonic sequence, issued and expiry times, direction, and ciphertext. Relay and endpoint checks cover version, time, size, direction, replay, and response correlation. Public button operations also contain the Watch-local commit time; a button older than three seconds is not executed after connectivity returns.

## Route selection

LAN is preferred whenever it is healthy. An active gesture or short queue is pinned to one route until completion so a later LAN action cannot overtake an earlier public action. Relay failure never creates an offline action queue. The UI must distinguish LAN, Internet, and offline; serialization or encryption alone is not action success.

## Profile consistency

Action profiles carry a revision. The Mac executes only after validating and installing the full target revision. Old revisions, missing buttons, and unsupported actions are rejected. Task state uses a separate monotonic state revision plus clear tombstones so an old completion summary cannot reappear after reconnect.

## Voice and task replies

The Watch sends PCM audio, while the Mac selects the speech locale, reorders packets, transcribes, and returns outcomes. Completed foreground dictation is immediately injected into the focused input by `BridgeTextInjector`; it does not enter a draft-confirmation flow. Codex voice is bound to the current task's thread, turn, and revision. The bridge invokes the local Codex CLI only when that exact task is still completed and the user has confirmed the draft.

`BridgeTextInjector` briefly writes the recognized text to the general system pasteboard and simulates Command-V. After approximately 450 ms, it restores the previous contents only if the pasteboard still contains that temporary text and has not changed. Other same-user processes may observe the text during this window. If another process changes the pasteboard, the bridge preserves the new contents instead of overwriting them, but the original contents may not be restored automatically.

## Persistence

| Data | Location |
|---|---|
| Action mappings, favorites, layout | Apple app-owned containers |
| Pairing identities, hook token, per-client relay credentials, E2E key | Apple Keychain |
| `ALLOWED_ROOM_ID`, `BOOTSTRAP_MAC_TOKEN` equal to the Mac bearer | Cloudflare Worker secret storage |
| Selected applications, task submission ledger | Bridge preferences or Application Support |
| Mac/device token SHA-256 hashes, relay device UUID, initialization time, replay/sequence, and rate state | Developer-owned Durable Object SQLite |
| Relay ciphertext | Not persisted |

Cloudflare edge processing also handles Bearer headers during authentication. Cloudflare and network providers can observe IP addresses, timing, size, frequency, and room URL paths. See the repository-root `THREAT_MODEL.md` for the complete boundary.
