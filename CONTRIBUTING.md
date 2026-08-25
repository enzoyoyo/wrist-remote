# Contributing

[简体中文](CONTRIBUTING.zh-CN.md)

Thank you for improving Wrist Remote. Contributions must preserve the project's explicit pairing, endpoint isolation, no-offline-command, and no-secret-in-repository boundaries.

## Before opening an issue

- Search existing issues and documentation.
- Run `make doctor`, `make test`, and `make build` when the development environment is available.
- Reduce reports to synthetic data and the smallest reproducible case.
- Remove names, email addresses, domains, IPs, device identifiers, Team IDs, Bundle prefixes, paths, tokens, transcripts, screenshots, logs, and provisioning files.
- Report vulnerabilities through GitHub private vulnerability reporting, not a public issue.

## Development setup

```bash
make setup
make doctor
make test
make build
make security
```

Use your own Apple Team and Cloudflare account. Never ask maintainers to accept a provisioning profile, certificate, Keychain export, account credential, or production secret.

## Pull requests

A pull request should:

- solve one bounded problem and explain user-visible behavior;
- include tests that fail before and pass after the change;
- update both `docs/en` and `docs/zh-CN` for developer-visible changes;
- preserve protocol compatibility or explicitly increment the correct version;
- keep generated projects, build products, dependencies, and local configuration out of Git;
- pass `make test`, `make build`, and `make security`;
- state which manual device checks were performed and which remain unverified.

Do not include private development notes, conversations, research records, full logs, or real user content in a commit or pull request.

## Security-sensitive changes

Changes to pairing, crypto, token handling, Keychain, Accessibility, speech, Codex submission, relay routing, protocol TTL, or replay logic require focused negative tests and a threat-model update.

The following changes are not accepted:

- arbitrary remote shell execution;
- public inbound listening on the Mac;
- credentials in URLs, source, examples, logs, or configuration committed to Git;
- persistence or delayed execution of offline button actions;
- silent permission bypass or fallback to unrelated applications;
- telemetry or hosted services enabled by default.

## Coding and protocol rules

- Generate Xcode projects from `project.yml`; do not commit generated projects.
- Use `npm ci` and keep `package-lock.json` current for relay dependency changes.
- Treat profile revisions and task state revisions as monotonic.
- Validate complete message shapes before executing an action.
- Keep the relay a one-room-per-deployment coordination unit.
- Limit Durable Object persistence to token hashes, the relay device UUID, initialization time, and replay/rate state; never persist ciphertext, plaintext payloads, bearer plaintext, or E2E keys there.
- Keep Watch gestures local so network latency cannot change their meaning.

## Documentation parity

Chinese and English documentation must contain the same commands, versions, limitations, and security disclosures. A translation may improve phrasing but must not weaken a warning or omit a known risk.

## Licensing

Wrist Remote is GPL-3.0-only. By contributing, you confirm that you created the contribution or otherwise have the right to provide it under GPL-3.0-only. Identify third-party sources and licenses in the pull request, and update `THIRD_PARTY_NOTICES.md` when applicable.

Do not submit assets or code with unclear provenance.

## Conduct

Participation is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
