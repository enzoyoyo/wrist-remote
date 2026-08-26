# Getting started

[简体中文](../zh-CN/getting-started.md)

Start with the LAN path and add the Internet relay only after local operation works. This isolates Apple signing, operating-system permissions, pairing, and mapping issues from public-network configuration.

## Components

- Apple Watch app: task state, remote buttons, favorites, voice entry, and local single/double/long-press resolution.
- iPhone companion: configuration for 36 action slots across 12 buttons, plus WatchConnectivity and LAN transport.
- Mac bridge: approved keyboard, media, and application actions; speech recognition; and the optional local Codex integration.
- Cloudflare relay: an optional one-room ciphertext relay deployed by each developer in their own Cloudflare account.

## Requirements

- macOS 13+, iOS 17+, and watchOS 10+.
- Full Xcode, Swift, XcodeGen, Git, ripgrep, Node.js 24+, and npm.
- Device installation requires the developer's own Apple Developer Team and development-ready iPhone and Apple Watch.
- Homebrew is not a runtime dependency. If XcodeGen is missing, `make setup` attempts a Homebrew installation only when Homebrew is already available.
- Internet mode additionally requires the developer's own Cloudflare account and Wrangler authentication.

## 1. Prepare the project

```bash
git clone https://github.com/OWNER/wrist-remote.git
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
WRISTREMOTE_RELAY_BASE_URL = https:/$()/relay.example.invalid
WRISTREMOTE_CODEX_EXECUTABLE_PATH =
```

Replace the Bundle prefix with a unique reverse-domain identifier you control and add your ten-character Team ID. Leave the reserved `.invalid` relay URL unchanged for LAN-only use. Never commit this file.

## 3. Install the Mac bridge

```bash
make install-mac
```

The default destination is the current user's `Applications` directory. An existing app is moved to a timestamped backup first. The script uses local ad-hoc signing by default; set `WRIST_CODESIGN_IDENTITY` for one invocation to use your own identity. This development install is not a Developer ID notarized distribution.

Grant only the permissions needed by enabled features:

- Local Network for companion discovery and LAN sessions.
- Accessibility for keyboard, media, and application-focus actions.
- Speech Recognition for converting Watch audio to text.

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

The installer automatically selects only a unique available iPhone, Apple Watch, and Apple Development identity. It fails closed on ambiguity. For one invocation only, use `WRIST_TEAM_ID`, `WRIST_IPHONE_UDID`, `WRIST_WATCH_UDID`, or `WRIST_DEVELOPER_DIR` to disambiguate. These values are not written to the repository.

Apple sign-in, device trust, Developer Mode, microphone, Accessibility, and Speech Recognition prompts require user confirmation. The scripts do not bypass platform security controls.

## 5. Pair and configure

1. Open the Mac bridge, iPhone app, and Watch app.
2. Let the iPhone discover the `_wristremote._tcp` service.
3. Compare the six-digit pairing code and approve only when both sides match.
4. Add permitted launch targets in the Mac bridge.
5. Configure favorites and each button's single, double, and long press on iPhone.
6. Test direction, OK, back, home, menu, TV, volume, and power mappings from the Watch.
7. Test haptics and both voice paths: completed foreground dictation should be injected immediately into the focused input, while Codex task voice remains a draft until the user confirms it.

## 6. Optional features

- [Deploy the Internet relay](relay-deployment.md)
- [Connect the Codex task hook](codex-integration.md)
- [Configuration reference](configuration.md)
- [Troubleshooting](troubleshooting.md)

## Acceptance boundary

`make test` and `make build` cover protocol logic, application logic, and unsigned builds. They do not prove real-device pairing, operating-system permissions, Watch haptics, Chinese recognition, route failover, or actual action execution. Complete the [release checklist](release-checklist.md) before a release.
