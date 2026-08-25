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

- The Mac bridge accepts LAN sessions only after explicit pairing and restricts local transport to LAN source addresses.
- Internet commands are end-to-end encrypted. The relay receives ciphertext and transport metadata, not plaintext actions, audio, summaries, or replies.
- Client copies of device/Mac credentials and the E2E key remain in Keychain. The Cloudflare Worker secret store holds the allowed room ID and bootstrap Mac bearer; Durable Object SQLite stores token hashes, a generated relay-device UUID, initialization time, and replay/rate-limit state.
- The relay has no offline command queue. Expired or replayed envelopes are rejected.
- The Codex hook binds to `127.0.0.1`, requires a random per-installation Bearer token, limits request size, and applies a short timeout.
- Signing credentials, provisioning profiles, local configuration, generated projects, logs, and build artifacts are excluded from source control.
- Wrist Remote uses its own identifiers and storage. It must not read, rewrite, or intercept unrelated remote-control or input-device configurations.

The full trust model and residual risks are documented in [THREAT_MODEL.md](THREAT_MODEL.md).

## Release requirements

A release must pass tests, unsigned builds, repository privacy checks, secret scanning, dependency audit, and a manual review of the exact Git tree. Source releases must not contain signed applications, archives, profiles, certificates, logs, or scan artifacts.
