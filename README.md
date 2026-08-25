# Wrist Remote

Private-by-design Apple Watch remote control for macOS, with an iPhone companion, a Mac bridge, and an optional self-hosted Internet relay.

[中文说明](README.zh-CN.md) · [English documentation](README.en.md)

Wrist Remote provides 12 virtual buttons with independent single-click, double-click, and long-press mappings. It supports keyboard shortcuts, media controls, launching developer-selected Mac apps, haptic feedback, Chinese speech-to-text, and optional Codex task summaries/replies.

The default build is LAN-only. Internet control remains disabled until the developer explicitly deploys a relay in their own Cloudflare account. The Mac accepts only outbound Internet relay connections; no inbound public port is opened.

## Quick start

```bash
git clone YOUR_PRIVATE_REPOSITORY_URL wrist-remote
cd wrist-remote
make setup
make doctor
make test
```

Then edit the ignored `Config/Local.xcconfig`, use `make install-mac`, and run `make install-devices` after Xcode, the iPhone, and Apple Watch are ready for development.

## Security boundaries

- Client copies of device/Mac credentials and the end-to-end key live in Keychain, never in the repository. Cloudflare's encrypted Worker secret store holds the allowed room ID and bootstrap Mac bearer required to operate a deployment.
- LAN pairing uses a dedicated protocol and explicit user confirmation.
- Durable Object SQLite stores credential hashes, a generated relay-device UUID, initialization time, and replay/rate-limit metadata—not plaintext commands, audio, or ciphertext.
- Relay payloads are end-to-end encrypted; Cloudflare can still observe transport metadata such as IP addresses, timing, size, and room paths.
- Codex hooks bind only to `127.0.0.1` and require a per-installation Bearer token.
- Wrist Remote uses its own Bundle IDs, storage, Bonjour service, ports, and mappings. It does not read or overwrite other input-device settings.

See [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), and [docs/en/architecture.md](docs/en/architecture.md).

## License

GPL-3.0-only. See [LICENSE](LICENSE). Apple, Apple Watch, iPhone, macOS, Codex, OpenAI, and Cloudflare are trademarks of their respective owners; this project is not affiliated with or endorsed by them.
