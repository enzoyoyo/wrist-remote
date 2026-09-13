# Getting started

[简体中文](../zh-CN/getting-started.md)

Start with the LAN path and add Tailscale only after local operation works. The checked-in personal build is private-only and does not expose a public Internet path. This isolates Apple signing, operating-system permissions, pairing, and mapping issues from private-network configuration.

## Components

- Apple Watch app: task state, remote buttons, favorites, voice entry, and local single/double/long-press resolution.
- iPhone companion: configuration for 36 action slots across 12 buttons, plus WatchConnectivity and LAN transport.
- Mac bridge: approved keyboard, media, and application actions; foreground-only system speech recognition; and optional Codex voice using the signed-in account's online transcription.
- Tailscale private-network mode: an optional iPhone-to-Mac fallback that remains private to the developer's tailnet.
- Public relay: disabled in the checked-in private-only build by `WRISTREMOTE_PRIVATE_ONLY = YES` and the independent `.invalid` endpoint gate.

## Requirements

- macOS 13+, iOS 17+, and watchOS 10+.
- Full Xcode, Swift, XcodeGen, Git, ripgrep, Node.js 24+, and npm.
- Device installation requires the developer's own Apple Developer Team and development-ready iPhone and Apple Watch.
- Homebrew is not a runtime dependency. If XcodeGen is missing, `make setup` attempts a Homebrew installation only when Homebrew is already available.
- Tailscale mode additionally requires the paired iPhone and Mac to join the same tailnet; the Watch itself does not join it.
- The private-only build requires no Cloudflare account or public service.

## 1. Prepare the project

Copy this repository's HTTPS or SSH clone URL from GitHub, then run:

```bash
git clone REPLACE_WITH_REPOSITORY_CLONE_URL
cd wrist-remote
make setup
make doctor
make test
```

`make setup` creates an ignored `Config/Local.xcconfig` with mode `0600`, regenerates both Xcode projects, and installs locked relay dependencies with `npm ci`. It does not sign in to Apple, register devices, authenticate Cloudflare, or create a public service.

## 2. Configure local signing

Edit `Config/Local.xcconfig`:

```xcconfig
WRISTREMOTE_BUNDLE_PREFIX = org.example.wristremote
WRISTREMOTE_DEVELOPMENT_TEAM = REPLACE_WITH_YOUR_TEAM_ID
WRISTREMOTE_PRIVATE_ONLY = YES
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

Replace the Bundle prefix with a unique reverse-domain identifier you control and add your ten-character Team ID. Keep both private-only gates unchanged for LAN/Tailscale use. Changing only one cannot enable a public path. Never commit this file.

## 3. Install the Mac bridge

```bash
make install-mac
```

The default destination is the current user's `Applications` directory. An existing app is moved to a timestamped backup first. The script automatically uses a single valid local `Apple Development` identity when one is available, producing a stable signature across reinstalls. It falls back to ad-hoc signing only when none exists, and refuses to guess when multiple identities are available. In that ambiguous case, provide one exact valid identity through the one-shot `WRIST_CODESIGN_IDENTITY` environment variable. Identity details are never printed or persisted by the script. This development install is not a Developer ID notarized distribution.

For a reviewed in-place upgrade at another location, run `scripts/build-macos.sh --install --target-app /absolute/path/WristRemoteBridge.app`. The target must be an absolute, non-symlinked `.app` whose Bundle ID matches the verified build. If the intended legacy Bridge uses a different, confirmed Bundle ID, set `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` in ignored `Config/Local.xcconfig` before rebuilding. Installation refuses to proceed while any `WristRemoteBridge` process is running or cannot be resolved to an exact app path; it never kills the app. Quit every Bridge normally, then retry. See [configuration.md](configuration.md#controlled-mac-bridge-upgrade).

Grant only the permissions needed by enabled features:

- Local Network for companion discovery and LAN sessions.
- Accessibility for keyboard, media, and application-focus actions.
- Speech Recognition only for foreground dictation. Codex online voice transcription does not use this permission.

The bridge does not need access to unrelated input-device or application preferences.

## 4. Install the iPhone and Watch apps

Run the read-only preflight first:

```bash
scripts/install-devices.command --dry-run
```

After Xcode is signed in and both unlocked devices have working development connections:

```bash
make install-devices
```

The installer automatically selects only a unique available iPhone, Apple Watch, and Apple Development identity. For Xcode, it first uses the active full stable installation selected by `xcode-select`; if that is ineligible, it chooses the highest installed stable release. Beta, RC, preview, seed, and other pre-release products are never auto-selected. Set `WRIST_DEVELOPER_DIR` for one invocation only when intentionally using a pre-release Xcode. Device or signing ambiguity fails closed and can be resolved for one invocation with `WRIST_TEAM_ID`, `WRIST_IPHONE_UDID`, or `WRIST_WATCH_UDID`. These values are not written to the repository, and device identifiers are not echoed in output.

The defaults are for a fresh installation. Preserving an existing iPhone/Watch app, its Keychain state, and pairing requires more than changing the Bundle prefix: follow the [controlled in-place upgrade](configuration.md#controlled-iphone-and-watch-in-place-upgrade), set both verified exact Bundle IDs, and enable the existing-install gate. `--dry-run` read-only checks the current Team, historical profiles, and live identities on both devices. An unreadable device, missing reviewed app, or same-named app under another identity stops the run.

Apple sign-in, device trust, Developer Mode, microphone, Accessibility, and Speech Recognition prompts require user confirmation. The scripts do not bypass platform security controls.

## 5. Pair and configure

1. Open the Mac bridge, iPhone app, and Watch app.
2. Let the iPhone discover the `_wristremote._tcp` service.
3. Compare the six-digit pairing code and approve only when both sides match.
4. Add permitted launch targets in the Mac bridge.
5. Configure favorites and each button's single, double, and long press on iPhone.
6. Test direction, OK, back, home, menu, TV, volume, and power mappings from the Watch.
7. Test haptics and both isolated voice paths: completed foreground dictation should be injected immediately into the focused input. Codex voice requires Internet access and a signed-in Codex account: first-party transcription returns text, which must be queued to the exact existing target without macOS Speech or the clipboard. Confirm the queue receipt; it does not mean the task has finished.
8. Create a **New task** and verify that the independent `thread/start` finishes before recording is enabled. Interrupt one recording and confirm that partial audio is deleted and never replayed after reconnect.

## 6. Optional features

- [Configure the Tailscale private network](tailscale-private-network.md)
- [Connect the Codex task hook](codex-integration.md)
- [Configuration reference](configuration.md)
- [Troubleshooting](troubleshooting.md)

## Acceptance boundary

`make test` and `make build` cover protocol logic, application logic, and unsigned builds. They do not prove real-device pairing, operating-system permissions, Watch haptics, foreground Chinese recognition, Codex transcription and task delivery, per-packet Mac acknowledgement, route handoff, or actual action execution. Complete the [release checklist](release-checklist.md) before a release.
