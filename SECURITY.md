# Security Policy

[中文](SECURITY.zh-CN.md)

## Supported versions

Security fixes are provided for the latest tagged release and the current `main` branch. Older releases may be asked to upgrade before receiving a fix.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting or Security Advisory feature for this repository. Do not include secrets, access tokens, room identifiers, device identifiers, personal data, local paths, private transcripts, or provisioning files in an issue.

If private reporting is unavailable, open a public issue containing only a request for a private contact channel. Do not disclose exploit details in that issue.

Useful, sanitized details include:

- affected commit or release;
- affected component: Watch, iPhone, Mac bridge, relay, or tooling;
- minimal reproduction using synthetic values;
- expected security boundary and observed behavior;
- impact and whether exploitation requires local, LAN, or Internet access.

Maintainers should acknowledge a complete report within seven days. A remediation timeline depends on impact and reproducibility. Please allow time for a coordinated fix before public disclosure.

## Security boundaries

- Before accepting TCP, the Mac bridge binds local transport to one concrete, non-publicly-routable address on an approved non-tunnel local interface (RFC1918 IPv4, IPv4 link-local, or IPv6 ULA) and fails closed when none exists. It then applies an independent LAN source-address gate before explicit pairing.
- Tailscale access is a separate, default-off listener. When enabled, it binds only one concrete `utun` address in Tailscale's official IPv4 or IPv6 ranges on TCP `60927`, accepts only a Tailscale-range source, and continues to require mutual Wrist Remote identity verification, explicit two-ended first pairing, and encrypted sessions.
- In the private-only build, the iPhone private-network setting accepts only an official Tailscale-range IP, is stored in the app's Keychain service, and is revalidated before use. DNS names, public URLs, embedded credentials, arbitrary ports, public IPs, and unrelated private IPs are rejected.
- Tailscale Funnel, router port forwarding, public reverse proxies, and public wildcard listeners are outside the supported design and must not be enabled for Wrist Remote. Tailnet Grants should restrict the intended source to `tcp:60927` on the intended Mac.
- The Mac and iPhone sign direct-handshake proofs with long-term P-256 identities stored in dedicated Keychain items and created only when those items are absent. The iPhone pins the Mac fingerprint only after local approval and Mac approval of the same six-digit session; the Mac independently stores the approved iPhone fingerprint.
- A changed Mac identity, unreadable or corrupt identity/trust store, invalid signature, incomplete transcript, unsigned legacy client, unavailable identity, or failed Mac-side persistence of an approved iPhone fingerprint fails closed before ready. The implementation does not silently rotate a stored identity or trust a replacement merely because the network endpoint appears unchanged.
- The checked-in personal build sets `WRISTREMOTE_PRIVATE_ONLY = YES` and retains the reserved `.invalid` relay URL. The build flag and endpoint validation are independent gates; neither can enable a public path alone. Historical relay credentials are revoked, and neither restart nor reinstall with retained Keychain state restores them.
- Relay source is retained only for separately reviewed variants. Tailscale Funnel, router port forwarding, public reverse proxies, and public wildcard listeners are not substitutes and remain unsupported.
- The Codex hook binds to `127.0.0.1`, requires a random per-installation Bearer token, limits request size, and applies a short timeout.
- Codex conversation capabilities are short-lived and destination-bound. **New task** performs an independent local `thread/start` with no fork or parent identifier, then converts the result into an existing target before recording can begin.
- Watch-to-Mac Codex voice uses the live private route through iPhone. The Mac writes an owner-only WAV, then sends the recording to Codex's fixed first-party online transcription service using the signed-in account's in-memory app-server authentication. After revalidating the target, the returned text is queued through local app-server stdin/stdout. This requires Internet access; private-only control does not mean offline transcription. Redirects and disk HTTP caching are disabled. Codex voice uses neither macOS Speech nor the pasteboard; audio, paths, authentication, and transcripts are excluded from Bridge logs and ledgers. Temporary recordings are deleted when processing finishes or is cancelled.
- Every audio packet in a continuous connection requires a Mac acceptance acknowledgement before the Watch advances. A disconnect or missing acknowledgement fails closed, discards partial audio, and is never automatically replayed after reconnect.
- Signing credentials, provisioning profiles, local configuration, generated projects, logs, and build artifacts are excluded from source control.
- A controlled Mac upgrade requires an absolute, non-symlinked target, a matching Bundle ID, and no running `WristRemoteBridge` process. The installer fails closed and never kills an existing Bridge; this reduces the chance of replacing the wrong app or racing a second listener on TCP `60927`.
- Wrist Remote uses its own identifiers and storage. It must not read, rewrite, or intercept unrelated remote-control or input-device configurations.

The Tailscale path still depends on the paired iPhone: the Watch itself does not join the tailnet, and independent cellular-Watch control is intentionally unavailable in the private-only build. An upgrade from a release without Mac identity pinning requires one explicit two-ended pairing. If a verified reinstall intentionally replaces the Mac identity, use **Forget trusted Mac** on the iPhone and pair again. If the iPhone identity itself is deliberately reset through **Reset this iPhone's pairing identity**, the Mac must approve it as a new iPhone. Never use either reset to bypass an unexplained mismatch. See [docs/en/tailscale-private-network.md](docs/en/tailscale-private-network.md) before enabling private-network access.

The full trust model and residual risks are documented in [THREAT_MODEL.md](THREAT_MODEL.md).

## Release requirements

A release must pass tests, unsigned builds, repository privacy checks, secret scanning, dependency audit, and a manual review of the exact Git tree. Direct-transport changes additionally require real-device validation of the LAN head start and first-ready route adoption, private-network connectivity, VPN wake-up, two-ended first pairing, pinned reconnect, identity-mismatch rejection, both explicit identity-recovery actions, persistence-failure denial, source rejection, and failure without queued execution. Codex changes additionally require real-device validation of independent task creation, exact target binding before and after online transcription, text-queue delivery, per-packet Mac acknowledgement, interruption cleanup, no automatic replay, and foreground-dictation isolation. Source releases must not contain signed applications, archives, profiles, certificates, logs, scan artifacts, real fingerprints, Tailscale IPs, account selectors, tailnet policy exports, or captured audio.
