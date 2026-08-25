# Deploy the Internet relay

[简体中文](../zh-CN/relay-deployment.md)

The relay is optional. The default reserved `.invalid` URL disables the Internet path; LAN control does not require Cloudflare.

## Security model

- Each developer deploys the Worker in their own Cloudflare account. The project provides no shared production relay.
- One deployment permits one random UUIDv4 room. Other rooms receive 404 before a Durable Object is created.
- The Mac initiates outbound WSS; no port forwarding, UPnP, or public inbound listener is needed.
- Commands, audio, profiles, summaries, and replies are end-to-end ChaChaPoly ciphertext. The E2E key is never sent to the Worker.
- Cloudflare edge processing handles Bearer headers during authentication. Worker secret storage retains `ALLOWED_ROOM_ID` and `BOOTSTRAP_MAC_TOKEN`, and the latter is the same value as the client-side Mac bearer.
- Durable Object SQLite persists SHA-256 hashes of the Mac/device tokens, the randomly generated relay device UUID, initialization time, and replay, sequence, and rate-limit state. It stores no bearer plaintext, E2E key, ciphertext, or plaintext payload.
- Cloudflare can still observe IP addresses, timing, request sizes, frequency, and room URL paths. The relay is not an anonymity network.
- Ciphertext exists in memory only while routing a request and waiting for its response. It is not written to SQLite and is not queued offline.

If Worker secrets leak, an attacker obtains the room ID and Mac bearer and can impersonate the Mac at the relay authentication layer, occupy the connection, or cause denial of service. Without the client E2E key, the attacker still cannot decrypt application payloads. Treat such disclosure as a security incident requiring immediate credential rotation and reprovisioning.

## Prerequisites

1. Complete [Getting started](getting-started.md) and set a unique Bundle prefix in `Config/Local.xcconfig`.
2. Use Node.js 24 or newer, matching CI.
3. Authenticate Wrangler with your own Cloudflare account:

```bash
cd apps/WristRemoteRelay
npx wrangler login
cd ../..
```

Do not store a Cloudflare API token in the repository, shell startup files, or command arguments.

## Deploy

```bash
make deploy-relay
```

The script performs these steps:

1. Verify local configuration and a unique Bundle prefix.
2. Install missing locked npm dependencies.
3. Generate Worker types, run strict TypeScript checks, and execute Vitest.
4. Deploy with the current Wrangler login.
5. Read the developer-owned HTTPS `workers.dev` URL from Wrangler output. If detection fails, provide `WRISTREMOTE_RELAY_BASE_URL` for that invocation only.
6. Securely generate or reuse room, device, two bearer tokens, and E2E key values locally.
7. Store bridge credentials in Keychain.
8. Set `ALLOWED_ROOM_ID` and `BOOTSTRAP_MAC_TOKEN` Worker secrets through stdin without printing values.
9. Update ignored `Config/Local.xcconfig` and retain mode `0600`.
10. Poll `/healthz` until configuration is ready.

When the updated Mac bridge first starts, it calls room initialization. Only then does the Worker store Mac/device token SHA-256 hashes, the randomly generated relay device UUID, initialization time, and replay, sequence, and rate-limit state in that room's SQLite storage. Client bearer and E2E credentials are stored by role in Apple Keychain on the Mac and iPhone/Watch; the two deployment secrets remain in Worker secret storage.

## Rebuild

The relay URL is build configuration, not a remotely delivered setting. After deployment, rebuild and reinstall all endpoints:

```bash
make install-mac
make install-devices
```

Connect once over LAN so the iPhone receives device provisioning from the bridge and forwards it to the Watch through WatchConnectivity.

## Health check

```bash
curl --fail "<RELAY_BASE_URL>/healthz"
```

Expected response:

```json
{"ok":true,"configured":true,"service":"wrist-remote-relay","protocolVersion":3}
```

Missing or malformed secrets produce HTTP 503 with `configured=false`. Health does not prove that the Mac is connected and never executes a button.

## API and limits

The Worker accepts root paths and an optional `/wristrelay` prefix:

| Method | Path | Authentication | Purpose |
|---|---|---|---|
| GET | `/healthz` | None | Configuration and protocol health |
| POST | `/v1/rooms/{room}/init` | Mac bearer | Write-once initialization; identical retry is idempotent |
| GET + Upgrade | `/v1/rooms/{room}/bridge` | Mac bearer | Outbound Mac WebSocket |
| POST | `/v1/rooms/{room}/command` | Device bearer | Encrypted command and synchronization operations |

Current limits:

- Relay protocol `3`.
- Decoded ciphertext up to 512 KiB; outer JSON up to 720 KiB.
- Frame lifetime up to 30 seconds with up to 30 seconds of clock skew.
- 120 authenticated command attempts per ten-second room window.
- At most 15 seconds waiting for the Mac.
- An offline Mac returns `mac_offline` immediately; nothing is queued.
- Watch buttons have a stricter three-second local commit freshness gate.

See [API](api.md) for response and error definitions.

## Custom domain

The repository contains no real route or account ID. If your fork adds a Cloudflare custom domain or route:

1. Keep HTTPS mandatory.
2. Supply the final root URL as `WRISTREMOTE_RELAY_BASE_URL` for deployment.
3. Rebuild all three endpoints.
4. Ensure root or `/wristrelay` prefix behavior matches the Worker route.
5. Repeat health and real-device Internet acceptance.

## Rotation, revocation, and deletion

The current provisioning tool reuses Keychain credentials under the same Bundle prefix. Re-deploying is not key rotation.

- Emergency revocation: disable/delete the Worker, or replace the allowed-room secret with a new random value. The old room becomes unreachable immediately.
- Full reprovisioning: quit the apps, use Keychain Access to remove the Wrist Remote relay credential for that Bundle prefix, then deploy and reinstall all endpoints. This is irreversible; preserve action mappings first.
- Complete deletion: delete the Worker, Worker secrets, Durable Object namespace, and matching Keychain/app data from the Apple devices and Mac.

Never send room IDs, tokens, E2E keys, or provisioning content through public issues, logs, or screenshots.

## Real-device acceptance

Verify at least:

1. LAN is selected while healthy.
2. While apps remain active, switch to a non-LAN network and observe the Internet route.
3. WAN latency does not change single/double/long-press meaning.
4. Buttons pressed while offline are not executed after reconnect.
5. An offline Mac produces an explicit failure.
6. Chinese foreground dictation completes recognition and immediate injection; Codex voice completes draft, confirmation, and final receipt end to end.
7. LAN recovery switches the route back automatically.

Use a non-destructive mapping for acceptance. CI and `/healthz` do not replace these steps.
