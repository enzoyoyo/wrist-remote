# Wrist Remote

Wrist Remote is a privacy-first Apple Watch → macOS remote-control stack consisting of an Apple Watch app, an iPhone companion, and a Mac bridge. The checked-in personal build is private-only: it supports LAN and an optional Tailscale direct route, while public relay operation is disabled.

[中文](README.zh-CN.md) · [Documentation index](docs/en/getting-started.md)

## Features

- An iPhone remote panel sharing mappings with Apple Watch, plus Mac pairing QR codes and independent phone/Watch connection status.
- Foreground Apple Watch button control directly over LAN with a separate device identity. Phone and Watch may connect together; authenticated action receipts distinguish confirmed execution from unconfirmed requests, which are never replayed after reconnect.
- 12 virtual buttons, each with independent single-click, double-click, and long-press actions: 36 mapping slots in total.
- Keyboard keys and shortcuts, media and volume control, Show Desktop, and app switching.
- Launch any Mac app explicitly selected by the developer; the repository ships no personal app catalog.
- Apple Watch haptics, favorites, spacious controls, and automatic reconnection.
- Watch microphone capture with two isolated paths. Foreground dictation uses the Mac Speech framework and temporary clipboard injection; Codex input uses the signed-in Codex native online transcription service and queues text to the selected task, without macOS dictation permission.
- Optional Codex integration that can browse recent conversations, select an exact destination, create an independent task, and submit held speech, while showing task status, summaries and the latest voice outcome on the home screen.
- LAN-head-start transport plus a Tailscale private-network candidate with no public listener. The private-only build does not support independent public-Internet control.
- Mutual installation identity: the Mac signs each direct handshake with a long-term P-256 identity, the iPhone pins that Mac fingerprint after two-ended confirmation, and the Mac pins the iPhone identity.

## Architecture

```text
Apple Watch
  ├─ foreground LAN buttons: application-encrypted HTTP → Mac Bridge
  ├─ relay / voice: WatchConnectivity → iPhone → Bonjour + encrypted TCP → Mac Bridge
  └─ private WAN: WatchConnectivity → iPhone → Tailscale TCP → Mac Bridge
```

The iPhone can also send remote buttons itself. Watch direct control uses HTTP `60929` on a concrete LAN address, not Tailscale; messages carry identity verification and application-layer encryption, while voice still uses the iPhone relay. See [phone and Watch setup](docs/en/phone-watch-connection.md) for QR pairing, independent Watch approval, and action receipts.

The LAN listener binds to one concrete, non-publicly-routable address on an approved non-tunnel local interface (RFC1918 IPv4, IPv4 link-local, or IPv6 ULA) and refuses to start when none exists. An independent Tailscale listener is off by default; when enabled, it binds only a concrete `utun` address in Tailscale's official ranges on fixed TCP port `60927`. Neither mode opens a public inbound port. `WRISTREMOTE_PRIVATE_ONLY = YES` disables public-relay operation at build configuration, while the reserved `.invalid` URL independently prevents provisioning or requests. Historical public credentials are revoked rather than reused.

## Requirements

- macOS 13+, iOS 17+, and watchOS 10+.
- Full Xcode 26 or newer, including installed iOS and watchOS Simulator runtimes, plus XcodeGen, Swift, Node.js 24+, and npm. The Mac target requires the macOS 26 SDK to compile; runtime availability checks preserve its older supported deployment target. CI uses Xcode 26.3.
- Device installation requires your Apple Developer Team and development-ready iPhone and Apple Watch.
- Private-network fallback requires Tailscale on the paired iPhone and Mac in the same tailnet; the Watch itself does not join the tailnet.
- The private-only build requires no Cloudflare account or public service.

## Ten-minute quick start

Copy this repository's HTTPS or SSH clone URL from GitHub, then run:

```bash
git clone REPLACE_WITH_REPOSITORY_CLONE_URL
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
WRISTREMOTE_PRIVATE_ONLY = YES
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

Replace the Bundle prefix and Team ID with your own values. Never commit this file.

Build and install the Mac bridge:

```bash
make install-mac
```

The default destination is `~/Applications/WristRemoteBridge.app`. An existing app is moved to a timestamped backup first. For a reviewed in-place upgrade at another location, run `scripts/build-macos.sh --install --target-app /absolute/path/WristRemoteBridge.app`; the target must be an absolute, non-symlinked `.app` whose Bundle ID matches the verified build. If an existing Bridge uses a deliberate legacy Bundle ID, set `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` in ignored `Config/Local.xcconfig` only after verifying that target. Installation refuses to continue while any `WristRemoteBridge` process is running and never kills it; quit the app normally, then retry. Signing happens only on the developer's Mac; no certificates, Team IDs, provisioning profiles, or pre-signed binaries are stored in the repository.

Install on connected devices:

```bash
make install-devices
```

The installer selects exactly one available iPhone, Apple Watch, and Apple Development identity, then builds, validates provisioning profiles, installs, and launches both apps. It fails closed on ambiguous devices or Teams. An existing installation must follow the [controlled in-place upgrade](docs/en/configuration.md#controlled-iphone-and-watch-in-place-upgrade) with both verified exact mobile Bundle IDs; the gate checks the current Team, historical profiles, and live identity on both devices to avoid a duplicate app or loss of Bundle-derived Keychain state.

Apple login, device trust, Developer Mode, Accessibility, microphone, and speech-recognition permission require user confirmation. Speech Recognition is used only for foreground dictation, not Codex original-audio input. The scripts do not bypass operating-system security prompts.

## Usage

1. Open the Mac bridge and grant Local Network and Accessibility permissions. Grant Speech Recognition only if foreground dictation is needed.
2. Connect from the iPhone companion. On first use or after upgrading from a release without Mac identity pinning, compare the same six-digit code and approve the connection on both the iPhone and Mac. The iPhone then pins the Mac identity and the Mac pins the iPhone identity.
3. Configure four favorites and each button's three gestures in the iPhone app.
4. To launch an app, add it in the Mac bridge first, then select that app profile in the iPhone mapping editor.
5. The paired iPhone gives LAN a 0.9-second head start. After explicit Tailscale setup, it also starts a candidate to the Mac's official Tailscale IP when LAN is not yet ready; the first-ready route is adopted. The private-only build deliberately does not provide independent cellular-Watch control without a reachable iPhone.

## Optional Tailscale private network

Install Tailscale on the Mac and paired iPhone, join the same tailnet, enable the Mac Bridge's private-network listener, then save the Mac's official Tailscale IPv4 or IPv6 address in the iPhone app. The private-only build rejects DNS names, URLs, ports, credentials, public IPs, and unrelated private IPs. Bonjour receives a 0.9-second head start. If no LAN candidate is ready and adopted by then, the iPhone also starts a Tailscale candidate on fixed TCP port `60927`; the first candidate to become ready is adopted and the other is cancelled. An adopted or connected route is not preempted, and the next reconnect cycle starts LAN-first again. A LAN failure or timeout starts Tailscale immediately.

The private listener is disabled by default and binds only an official Tailscale address on a `utun` interface. Wrist Remote's mutual identity verification, two-ended first approval, and application-layer encryption remain mandatory. A later Mac identity change fails closed. Do not use Tailscale Funnel, router port forwarding, a public proxy, or a public listener. Termius may be used separately for SSH diagnostics but is not an app transport.

Read [docs/en/tailscale-private-network.md](docs/en/tailscale-private-network.md) for official-IP validation, VPN On Demand, least-privilege Grants, real-device acceptance, and troubleshooting.

## Public relay is disabled in the private-only build

The tracked configuration and the local example both set `WRISTREMOTE_PRIVATE_ONLY = YES` and retain the `.invalid` relay URL. These are independent gates: changing only the URL cannot enable a public path, and changing only the build flag still leaves provisioning disabled. Relay source remains in the repository for separately reviewed variants, but it is not a runtime option in this personal build. Do not use Funnel, port forwarding, or a public proxy as a substitute.

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
| `make deploy-relay` | Relay-development tooling; not operational in a `WRISTREMOTE_PRIVATE_ONLY = YES` build |
| `make security` | Scan paths, credentials, keys, forbidden files, and Git history |
| `make verify` | Run the complete release gate, including dependency audit and Simulator tests |

API examples are in [docs/en/api.md](docs/en/api.md). Contribution instructions are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Security and privacy

- Direct commands, audio, task summaries, and outcomes are encrypted between the paired iPhone and Mac.
- In the private-only build, Tailscale mode accepts only official Tailscale-range IPs on the iPhone and only a concrete Tailscale `utun` address/source on the Mac; the setting is off by default and does not weaken application pairing or encryption.
- The Mac and iPhone long-term P-256 identities, the iPhone's pinned Mac fingerprint, and the Mac's trusted iPhone fingerprints are stored in dedicated, Bundle-derived Keychain services. Each identity is created only when its item is absent; corrupt or unreadable state fails closed instead of silently rotating trust. A Mac-side failure to persist an approved iPhone fingerprint denies the session before it becomes ready.
- Codex hooks are loopback-only, size-limited, timeout-bounded, and Bearer-authenticated.
- Selecting **New task** first performs an independent `thread/start` with no fork or parent, then registers the result as an existing target; recording remains disabled until that exact target is ready.
- Codex voice streams PCM through the live private route and writes an owner-only temporary WAV on the Mac. Codex's first-party online service transcribes it, then local app-server queues text to the exact task. Credentials, transcript, path and audio stay out of Bridge logs and ledgers. Queued does not mean completed; transcription failures explicitly report not sent.
- Each continuous-stream packet advances only after the Mac acknowledges acceptance. A disconnect fails closed, deletes the partial recording, and never automatically replays it.
- General dictation briefly uses the macOS clipboard to paste into the foreground app, then conditionally restores the previous clipboard contents.
- Codex completion notifications use generic text and carry no task title, summary, or conversation identifiers.
- When a signed build keeps the relay URL at `.invalid`, all three apps refuse historical public-relay provisioning; the Bridge emits an explicit tombstone and the iPhone and Watch delete the corresponding Keychain item.
- Dedicated Bundle IDs, Keychain services, Bonjour service, ports, preferences, and mappings prevent cross-device configuration writes.

Read [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), and [THREAT_MODEL.md](THREAT_MODEL.md).

## Known boundaries

- CI cannot replace real-device validation of pairing, permissions, haptics, Watch audio, per-packet Mac acknowledgement, VPN wake-up, or LAN-to-Tailscale handoff.
- Tailscale direct mode depends on a reachable paired iPhone. Independent cellular-Watch control is intentionally unavailable in the private-only build.
- Upgrading from a version that did not pin the Mac requires one explicit two-ended pairing. If an intentional Mac reinstall or Keychain reset changes the identity later, use **Forget trusted Mac** in the iPhone app, then compare and approve the new six-digit code on both ends. If the iPhone installation identity itself is intentionally reset through **Reset this iPhone's pairing identity**, the Mac treats it as a new iPhone and must approve it again. Never use either reset to bypass an unexpected identity warning.
- iOS/watchOS apps require each developer's own Apple signing identity; there is no universal installable IPA.
- The initial release ships source only, not maintainer-signed applications or provisioning artifacts.
- Conversation listing, independent task creation, destination locking, original-audio delivery, disconnect fail-closed behavior, and receipts still require end-to-end acceptance on the intended Mac, iPhone, and Watch; automated tests do not replace this gate.

## License and trademarks

GPL-3.0-only; see [LICENSE](LICENSE). Apple, Apple Watch, iPhone, macOS, Codex, OpenAI, and Cloudflare are trademarks of their respective owners. This project is not affiliated with or endorsed by them.
