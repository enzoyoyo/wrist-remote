# Wrist Remote

Wrist Remote is a privacy-first Apple Watch → macOS remote-control stack consisting of an Apple Watch app, an iPhone companion, a Mac bridge, and an optional self-hosted Internet relay.

[中文](README.zh-CN.md) · [Documentation index](docs/en/getting-started.md)

## Features

- 12 virtual buttons, each with independent single-click, double-click, and long-press actions: 36 mapping slots in total.
- Keyboard keys and shortcuts, media and volume control, Show Desktop, and app switching.
- Launch any Mac app explicitly selected by the developer; the repository ships no personal app catalog.
- Apple Watch haptics, favorites, spacious controls, and automatic reconnection.
- Watch microphone capture with Chinese speech recognition on the Mac. General dictation is inserted into the foreground app; Codex task replies remain drafts until confirmed.
- Optional Codex integration for current-task status, completion summaries, and confirmed voice replies.
- LAN-first transport, plus an optional Cloudflare Worker and Durable Object relay for Internet control.

## Architecture

```text
Apple Watch
  ├─ LAN: WatchConnectivity → iPhone → encrypted TCP → Mac Bridge
  └─ WAN: end-to-end encrypted HTTPS → your Cloudflare relay
                                              ↓
                                      outbound WSS from Mac
```

The LAN listener binds to one concrete, non-publicly-routable address on an approved non-tunnel local interface (RFC1918 IPv4, IPv4 link-local, or IPv6 ULA) and refuses to start when none exists. The Mac does not open a public inbound port. Until a developer deploys a relay, shared provisioning validation rejects the reserved `.invalid` URL before provisioning is accepted or any network request starts.

## Requirements

- macOS 13+, iOS 17+, and watchOS 10+.
- Full Xcode, including installed iOS and watchOS Simulator runtimes, plus XcodeGen, Swift, Node.js 24+, and npm.
- Device installation requires your Apple Developer Team and development-ready iPhone and Apple Watch.
- The optional relay requires your Cloudflare account and a Wrangler login.

## Ten-minute quick start

```bash
git clone YOUR_PRIVATE_REPOSITORY_URL wrist-remote
cd wrist-remote
make setup
make doctor
make test
```

`make setup` ensures XcodeGen, ripgrep, and Gitleaks are present (using Homebrew when available), creates an ignored `Config/Local.xcconfig` with mode `0600`, generates both Xcode projects from `project.yml`, and installs the relay's locked npm dependencies.

Edit the local configuration:

```xcconfig
WRISTREMOTE_BUNDLE_PREFIX = org.example.wristremote
WRISTREMOTE_DEVELOPMENT_TEAM = REPLACE_WITH_YOUR_TEAM_ID
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

Replace the Bundle prefix and Team ID with your own values. Never commit this file.

Build and install the Mac bridge:

```bash
make install-mac
```

The default destination is `~/Applications/WristRemoteBridge.app`. An existing app is moved to a timestamped backup first. Signing happens only on the developer's Mac; no certificates, Team IDs, provisioning profiles, or pre-signed binaries are stored in the repository.

Install on connected devices:

```bash
make install-devices
```

The installer selects exactly one available iPhone, Apple Watch, and Apple Development identity, then builds, validates provisioning profiles, installs, and launches both apps. It fails closed on ambiguous devices or Teams.

Apple login, device trust, Developer Mode, Accessibility, microphone, and speech-recognition permission require user confirmation. The scripts do not bypass operating-system security prompts.

## Usage

1. Open the Mac bridge and grant Local Network, Accessibility, and Speech Recognition permissions.
2. Connect from the iPhone companion. On first use, compare and approve the six-digit code on both devices.
3. Configure four favorites and each button's three gestures in the iPhone app.
4. To launch an app, add it in the Mac bridge first, then select that app profile in the iPhone mapping editor.
5. The Watch prefers LAN when available and can use the Internet path only after explicit relay provisioning.

## Optional Internet relay

```bash
make deploy-relay
```

The command runs type checks and 21 relay tests before deploying to the currently authenticated Cloudflare account. It generates or reuses one-room credentials, stores Mac credentials and E2E keys in Keychain, sends Worker secrets through stdin without printing their values, updates the ignored relay URL, and verifies `/healthz`.

The relay is a public HTTPS endpoint, but it does not expose the Mac or Apple devices as public servers. Read [docs/en/relay-deployment.md](docs/en/relay-deployment.md) and [THREAT_MODEL.md](THREAT_MODEL.md) before enabling it.

## Optional Codex integration

The bridge listens only on `127.0.0.1:60928/codex-hook` and requires a random per-installation Bearer token stored in Keychain. `scripts/codex-notify.sh` retrieves that token and forwards hook JSON from stdin without placing the token in the repository or shell history.

Copy [examples/codex-hooks.json](examples/codex-hooks.json) outside the repository, replace `<REPO_ROOT>` with your clone's absolute path, and merge it into your own hook configuration. Never commit the customized file or overwrite unrelated hooks. See [docs/en/codex-integration.md](docs/en/codex-integration.md).

## Developer commands

| Command | Purpose |
|---|---|
| `make setup` | Prepare tools, local config, Xcode projects, and npm dependencies |
| `make doctor` | Run read-only environment checks |
| `make icons` | Regenerate every app icon from the repository's geometric source |
| `make test` | Run Swift, bridge, and relay tests |
| `make relay-audit` | Audit locked relay dependencies for high-severity vulnerabilities |
| `make test-simulators` | Run iOS unit tests and the offline watchOS UI smoke tests |
| `make build` | Build unsigned iOS/watchOS Simulator and macOS targets |
| `make install-mac` | Locally sign and install the Mac bridge |
| `make install-devices` | Sign and install iPhone/Watch apps with the developer's Team |
| `make deploy-relay` | Deploy and initialize the optional private relay |
| `make security` | Scan paths, credentials, keys, forbidden files, and Git history |
| `make verify` | Run the complete release gate, including dependency audit and Simulator tests |

API examples are in [docs/en/api.md](docs/en/api.md). Contribution instructions are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Security and privacy

- Client copies of the device/Mac credentials and E2E key remain in Apple Keychain. Cloudflare's encrypted Worker secret store holds the allowed room ID and bootstrap Mac bearer; Durable Object SQLite stores token hashes, a generated relay-device UUID, initialization time, and replay/rate-limit state.
- Commands, audio, task summaries, and replies are end-to-end encrypted between the device and Mac.
- The relay stores no ciphertext and has no offline queue. Requests fail immediately when the Mac is offline.
- Cloudflare terminates HTTPS and can observe Bearer headers plus IP addresses, timing, sizes, request frequency, and room URL paths. It cannot decrypt application payloads without the separate E2E key. This is not an anonymity system.
- Codex hooks are loopback-only, size-limited, timeout-bounded, and Bearer-authenticated.
- Codex voice replies require explicit confirmation before submission.
- General dictation briefly uses the macOS clipboard to paste into the foreground app, then conditionally restores the previous clipboard contents.
- Codex completion summaries may appear in Watch notification previews according to system settings.
- Dedicated Bundle IDs, Keychain services, Bonjour service, ports, preferences, and mappings prevent cross-device configuration writes.

Read [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), and [THREAT_MODEL.md](THREAT_MODEL.md).

## Known boundaries

- CI cannot replace real-device validation of pairing, permissions, haptics, Watch audio, and Internet failover.
- iOS/watchOS apps require each developer's own Apple signing identity; there is no universal installable IPA.
- The initial release ships source only, not maintainer-signed applications or provisioning artifacts.
- Codex CLI currently accepts confirmed text through `queue --message`, which places it briefly in a local process argument. Software running as the same macOS user with process-inspection access may observe it. See the threat model.

## License and trademarks

GPL-3.0-only; see [LICENSE](LICENSE). Apple, Apple Watch, iPhone, macOS, Codex, OpenAI, and Cloudflare are trademarks of their respective owners. This project is not affiliated with or endorsed by them.
