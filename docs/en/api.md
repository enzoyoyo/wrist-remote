# Developer interfaces and protocols

[简体中文](../zh-CN/api.md)

This page documents the current versioned wire surfaces: relay protocol 3, LAN/Watch protocol 7, action profile format 1, and the local Codex hook. Protocol versions require an exact match and do not silently downgrade. The Swift files under `apps/WristRemote/Shared` are an internal application implementation and test target, not an exported SwiftPM SDK.

## Relay HTTP/WSS API

All JSON responses use `Content-Type: application/json` and `Cache-Control: no-store`. Credentials belong in `Authorization: Bearer ...`; a URL containing `macToken` or `deviceToken` query parameters is rejected.

### Health

```http
GET /healthz
```

A configured deployment returns 200:

```json
{"ok":true,"configured":true,"service":"wrist-remote-relay","protocolVersion":3}
```

### Initialize a room

```http
POST /v1/rooms/{roomUUID}/init
Authorization: Bearer <MAC_TOKEN>
Content-Type: application/json
```

The body contains `deviceID` and a 32-byte unpadded-base64url `deviceToken`. The first matching initialization returns 201, an identical retry returns 200, and changed credentials return 409. Do not hand-build production initialization; use `make deploy-relay`.

### Bridge WebSocket

```http
GET /v1/rooms/{roomUUID}/bridge
Authorization: Bearer <MAC_TOKEN>
Upgrade: websocket
```

A new authenticated connection replaces the old bridge. The relay sends:

```json
{"type":"relayRequest","requestID":"<uuid>","frame":{"...":"encrypted frame"}}
```

The bridge returns `relayResponse` with the same `requestID`. The text `ping` receives `pong` through the Durable Object hibernation auto-response.

### Device command

```http
POST /v1/rooms/{roomUUID}/command
Authorization: Bearer <DEVICE_TOKEN>
Content-Type: application/json
```

Outer frame fields:

| Field | Type | Meaning |
|---|---|---|
| `protocolVersion` | integer | Must be 3 |
| `operationID` | UUID | Request/response correlation and deduplication |
| `senderID` | UUID | Sequence isolation domain |
| `sequence` | non-negative integer | Monotonic per sender and direction |
| `issuedAtEpochMilliseconds` | integer | Issue time |
| `expiresAtEpochMilliseconds` | integer | Expiry time |
| `direction` | string | `deviceToMac` or `macToDevice` |
| `ciphertext` | base64 | ChaChaPoly combined data |

Header fields are authenticated data. The operation is available only after decrypting ciphertext.

Operation kinds are `status`, `profileUpdate`, `buttonEvent`, `voiceStart`, `audio`, `voiceStop`, and `codexReplySubmit`.

### Relay errors

Stable error shape:

```json
{"error":{"code":"mac_offline","message":"Mac bridge is not connected; nothing was queued."}}
```

Common codes:

| HTTP | Code | Meaning |
|---:|---|---|
| 400 | `invalid_frame`, `invalid_json`, `invalid_room_id` | Bad shape, time, or direction |
| 401 | `unauthorized` | Missing or wrong bearer |
| 404 | `room_not_found`, `room_not_initialized`, `not_found` | Unknown room or route |
| 409 | `room_already_initialized`, `replay_detected` | Credential conflict or replay |
| 413 | `payload_too_large`, `ciphertext_too_large_or_invalid` | Size limit exceeded |
| 415 | `unsupported_media_type` | Body is not JSON |
| 429 | `rate_limited` | Room limit exceeded; includes `Retry-After` |
| 502 | `bridge_disconnected`, `bridge_replaced`, `invalid_bridge_response` | Broken bridge session or invalid response |
| 503 | `private_relay_not_configured`, `mac_offline` | Missing configuration or offline Mac |
| 504 | `relay_timeout` | No bridge response within 15 seconds |

## LAN / Watch protocol 7

LAN uses `_wristremote._tcp` on TCP `60927`. Its handshake, six-digit verification, and encrypted session are not an HTTP API. Primary message kinds are:

- `buttonEvent`: command, press/release phase, and profile revision.
- `voiceStart` / `voiceStop`: stream ID, voice intent, and optional task identity.
- `requestStatus` / `status`: connection, profile, favorites, titles, voice, task, and relay provisioning.
- `favoritesUpdate`: four favorite buttons.
- `codexTaskSnapshot`: a snapshot or explicit clear tombstone.
- `voiceOutcome`: transcript and final-audio acknowledgement.
- `codexReplySubmit`: confirmed text, submission ID, and exact task identity.

The bundled apps use the internal constructors and validators in `apps/WristRemote/Shared`. External integrations should use the documented hook and relay surfaces; do not treat those internal Swift types as a public package API or bypass the wire schemas with handwritten production messages.

## Action profile format 1

Button IDs:

```text
power, up, left, ok, right, down, back, volume_up,
home, volume_down, menu, tv
```

Each button must contain `singleClick`, `doubleClick`, and `longPress`. Binding shape:

```json
{
  "action": "customShortcut",
  "shortcut": {
    "keyCode": 0,
    "modifierFlagsRawValue": 0,
    "keyLabel": "Example"
  },
  "applicationProfileID": null
}
```

`customShortcut` requires a valid shortcut. `openCustomApplication` requires a UUID profile ID assigned by the bridge.

## Codex hook API

```http
POST http://127.0.0.1:60928/codex-hook
Authorization: Bearer <KEYCHAIN_TOKEN>
Content-Type: application/json
Content-Length: ...
```

Production callers should use:

```bash
scripts/codex-notify.sh < hook-event.json
```

The script securely retrieves the Keychain token. Do not place the bearer in example commands, source files, or shell history. See [Codex integration](codex-integration.md) for fields and responses.

## Compatibility policy

- Relay, LAN, and profile formats are versioned independently.
- A field intended for old endpoints must be optional and tested both absent and present.
- Changes to gesture semantics, key-derivation domains, direction, TTL, profile completeness, or task identity require the corresponding version change.
- Incompatible versions fail explicitly; they do not fall back to unauthenticated or unrelated application transports.
