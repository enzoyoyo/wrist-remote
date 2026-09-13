# Wrist Remote

Private-by-design iPhone and Apple Watch remote control for macOS, with a dedicated Mac bridge. The checked-in build is private-only: LAN and an optional iPhone Tailscale route are supported, while the public relay is disabled by both build metadata and the reserved `.invalid` endpoint.

[中文说明](README.zh-CN.md) · [English documentation](README.en.md)

Wrist Remote provides 12 virtual buttons on iPhone and Apple Watch, sharing 36 independent single-click, double-click, and long-press mappings. It supports keyboard shortcuts, media controls, launching explicitly selected Mac apps, haptic feedback, foreground Chinese dictation, and optional Codex task summaries and voice input. Codex voice uses the signed-in account's online transcription service, then queues text to the selected task.

The private-only build gives LAN a head start and may use a separately enabled Tailscale listener. The LAN listener binds to one concrete, non-publicly-routable address on an approved non-tunnel local interface; the Tailscale listener binds only an official Tailscale-range `utun` address and accepts only Tailscale-range sources. Neither route opens a public inbound port, and Funnel, port forwarding, public proxies, and public wildcard listeners are unsupported.

## Quick start

iPhone can act as a remote itself, with 12 buttons and 36 gesture mappings shared with Apple Watch. Scan the Mac bridge's pairing QR code using the iPhone system camera, compare the six-digit code, and approve both ends; the QR code alone does not authorize a device. Open the phone remote from the iPhone home screen. Apple Watch can send buttons directly over LAN HTTP `60929` while its app is foregrounded; enable direct Mac connection on Watch and approve its independent identity separately. Phone and Watch can stay connected together, with per-device status and authenticated action receipts. Watch voice still uses the iPhone relay, and Watch direct control does not add a public or Tailscale route.

See [phone and Watch setup](docs/en/phone-watch-connection.md) for pairing, connection paths, and execution confirmation.

```bash
git clone https://github.com/OWNER/wrist-remote.git
cd wrist-remote
make setup
make doctor
make test
```

Then edit the ignored `Config/Local.xcconfig`, use `make install-mac`, and run `make install-devices` after Xcode, the iPhone, and Apple Watch are ready for development.

## Security boundaries

- Installation identities, pinned fingerprints, private endpoint state, and the Codex hook bearer live in Keychain, never in the repository. The active private-only build has no Cloudflare credential or public Relay dependency; Relay credentials belong only to a separately reviewed variant.
- LAN transport uses pre-bind address isolation, an independent post-accept source gate, a dedicated protocol, and explicit user confirmation.
- The checked-in private-only build sets `WRISTREMOTE_PRIVATE_ONLY = YES` and keeps the relay URL at `.invalid`; both gates must agree before any public-relay code can become operational.
- Codex speech uses the signed-in Codex native transcription service, then queues its text to the exact selected task. Temporary audio is owner-only, and credentials/audio/transcripts stay out of Bridge logs and ledgers. This needs internet access; foreground dictation alone uses macOS Speech and the temporary clipboard path.
- **New task** first completes an independent `thread/start` with no parent/fork identifier and becomes an existing target; voice remains disabled until that transition succeeds.
- Audio packets receive a Mac delivery acknowledgement before the Watch advances. A disconnect fails closed and does not replay the recording later.
- Codex hooks bind only to `127.0.0.1` and require a per-installation Bearer token.
- Wrist Remote uses its own Bundle IDs, storage, Bonjour service, ports, and mappings. It does not read or overwrite other input-device settings.

See [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), and [docs/en/architecture.md](docs/en/architecture.md).

## License

GPL-3.0-only. See [LICENSE](LICENSE). Apple, Apple Watch, iPhone, macOS, Codex, OpenAI, and Cloudflare are trademarks of their respective owners; this project is not affiliated with or endorsed by them.
