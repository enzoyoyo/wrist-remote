# Threat model

## Scope and security goals

Wrist Remote carries user-triggered remote actions, short audio captures, speech transcripts, task status, summaries, and confirmed replies between an Apple Watch, its companion iPhone, a Mac bridge, and an optional self-hosted relay.

The design aims to:

- prevent an unauthenticated LAN or Internet peer from executing commands;
- keep application payloads confidential from the relay;
- reject expired, duplicated, and replayed command envelopes;
- avoid opening a public inbound port on the Mac;
- isolate its identifiers and storage from unrelated devices and applications;
- keep signing material, credentials, and personal development artifacts outside the repository.

## Trust boundaries

```text
Watch ── WatchConnectivity ── iPhone ── encrypted LAN TCP ── Mac Bridge
  └──────── E2E encrypted HTTPS ─────── self-hosted Relay ── outbound Mac WSS
Codex hook producer ── authenticated loopback HTTP ── Mac Bridge ── local Codex CLI
```

The Watch, iPhone, and Mac are trusted after explicit user pairing. Keychain and the operating-system permission model are trusted. The LAN, Internet, DNS, and relay platform are untrusted for application payload confidentiality and command authenticity.

## Controls

### Local transport

- First use requires a six-digit user-verification ceremony.
- Session keys are negotiated per pairing/session and authenticated encryption protects frames.
- The listener binds before accept to one concrete, non-publicly-routable address on an approved non-tunnel local interface: RFC1918 IPv4, IPv4 link-local, or IPv6 ULA. No safe address means no listener.
- After accept, the bridge independently restricts peers to allowed LAN source addresses and bounds message sizes and timeouts.

### Internet transport

- The Mac establishes the outbound WebSocket; it is not an Internet-facing server.
- Device and Mac tokens are independent. Cloudflare's Worker secret store keeps the allowed room ID and bootstrap Mac bearer used to initialize and gate the deployment. Durable Object SQLite persists token hashes, a generated relay-device UUID, initialization time, and replay/rate-limit state.
- Application envelopes are end-to-end encrypted with a key provisioned to clients and the Mac, not the relay.
- Envelope IDs, timestamps, TTL checks, and replay state prevent stale or duplicate execution.
- There is no offline queue and no ciphertext persistence.

### Local hook

- The HTTP listener binds only to `127.0.0.1`.
- Every request requires a random per-installation Bearer token stored in Keychain.
- Authentication comparison is constant-time; headers, body length, and processing time are bounded.
- Voice-derived text requires user confirmation before the bridge invokes Codex.

### Build and release

- Repository defaults point to the reserved `.invalid` domain, which shared provisioning validation rejects before provisioning is accepted or any network request starts.
- Production configuration is ignored by Git and stored with restrictive permissions.
- Signing happens locally with each developer's identity. Source releases contain no signed artifacts.
- CI uses unsigned builds and receives no production Apple, Cloudflare, relay, or Keychain secrets.

## Residual risks

- A compromised Apple device or Mac user account can access content after decryption and may exercise granted Accessibility, microphone, or speech-recognition permissions.
- Software running as the same macOS user may be able to inspect process arguments. The current Codex CLI `queue --message` interface briefly exposes a confirmed reply in the local process argument list.
- General dictation briefly places the transcript on the macOS general clipboard before simulating paste. Same-user software may observe it, and an unrelated concurrent clipboard update can prevent restoration of the prior value.
- Watch completion notifications contain the task summary or title and task identifiers. System notification previews may expose that text on the lock screen or in Notification Center according to the user's settings.
- Cloudflare terminates HTTPS and can observe Bearer headers. The relay operator, Cloudflare, DNS providers, and network providers can also observe transport metadata, including IP addresses, timing, sizes, frequency, and room URL paths.
- Compromise of the Worker secret store can expose the bootstrap Mac bearer, enabling Mac impersonation or denial of service. Without the separately provisioned E2E key, that compromise alone does not reveal application plaintext.
- A leaked device token, Mac token, or E2E key remains sensitive until credentials are reprovisioned and the affected local Keychain data is replaced.
- Denial of service, traffic analysis, endpoint compromise, malicious local accessibility software, and compromised Apple or Cloudflare accounts are outside the confidentiality guarantee.
- CI and simulator tests do not prove real-device pairing, haptics, speech recognition, permission prompts, or Internet failover.

## Non-goals

Wrist Remote is not an anonymity network, mobile-device-management system, general remote shell, multi-tenant hosted service, or mechanism for bypassing Apple permissions and code-signing controls.
