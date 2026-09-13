# Development guide

[简体中文](../zh-CN/development.md)

## Repository layout

| Path | Content |
|---|---|
| `apps/WristRemote/iOS` | iPhone companion |
| `apps/WristRemote/Watch` | Apple Watch app |
| `apps/WristRemote/Shared` | Application-internal shared protocols, profiles, relay crypto, and test target |
| `apps/WristRemoteBridge/Sources` | macOS bridge, actions, speech, and Codex integration |
| `apps/WristRemoteRelay` | Cloudflare Worker, Durable Object, and tests |
| `Config` | Tracked safe defaults and ignored local overrides |
| `scripts` | Build, install, deploy, diagnostic, and security entry points |
| `docs` | Chinese and English developer documentation |

Xcode projects, generated Info.plist files, DerivedData, Swift `.build`, `node_modules`, and Wrangler state are reproducible and must not enter Git.

Types under `apps/WristRemote/Shared` are not currently an external `public` API. Integrations for the current private-only build should use the UI or Codex loopback hook and must not assume that another Swift package can directly import or construct these internal types. Relay HTTP/WSS source belongs to a separately reviewed variant and is inactive when `WRISTREMOTE_PRIVATE_ONLY = YES` and the endpoint is `.invalid`.

## Common commands

Build with Xcode 26 or newer: the Mac source requires the macOS 26 SDK even though newer speech APIs are guarded at runtime. CI pins Xcode 26.3 through a job-scoped `DEVELOPER_DIR`. `make build` and `make test` use `doctor.sh --unsigned`, so the example configuration can be used without a personal signing identity; installation and default `make doctor` retain strict identity checks.

```bash
make setup       # tools, Local.xcconfig, XcodeGen, and npm ci
make doctor      # read-only environment checks
make test        # Swift package, bridge XCTest, relay check
make relay-audit # high-severity audit of locked relay dependencies
make test-simulators # iOS XCTest and offline watchOS UI smoke tests
make build       # unsigned builds for all Apple targets
make install-mac # stable local signing when uniquely available, then controlled install
make security    # path, credential, and Git-history scan
make verify      # complete release gate, including audit and Simulator tests
make clean       # remove only explicit generated directories
```

`make setup` may install XcodeGen when Homebrew is already available, so it can change the development machine. `make doctor` installs and modifies nothing. Simulator runtime compatibility is checked by `make test-simulators` and the complete `make verify` gate, not by `make doctor`.

The Mac installer selects exactly one valid local `Apple Development` identity automatically. Multiple matches fail closed and require an exact one-shot `WRIST_CODESIGN_IDENTITY`; zero matches use ad-hoc signing. The helper and its regression fixtures must not print or persist certificate names, hashes, or Team IDs. See [configuration.md](configuration.md#mac-build-signing-selection).

## Test layers

- Shared Swift tests: profile completeness, protocol shapes, connection state, relay crypto, and gesture resolution.
- Bridge XCTest: actions, pairing source restrictions, profile sessions, foreground speech, Codex online transcription/temp-file handling, independent task creation, hook/text submission, and isolation boundaries.
- Relay check: Wrangler type generation, two TypeScript type checks, and Workers-runtime Vitest.
- Simulator tests: the iOS XCTest target plus seven offline watchOS UI tests covering home, all remote pages, explicit destination selection, repeated dismissal, long titles, large text, complete destination reading, and voice-status dismissal.
- Unsigned builds: iOS Simulator, watchOS Simulator, and macOS Release compilation.
- Connected/manual testing: the remaining watchOS UI tests require a live bridge; real-device checks cover pairing, permissions, all 36 mapping slots, haptics, Chinese foreground dictation, Codex transcription and text-queue receipts, per-packet Mac acknowledgement, LAN/Tailscale failover, no public fallback, and lifecycle reconnect.

The automated layers do not replace connected or real-device testing. If the operating system lacks the required Simulator runtimes or cannot enable UI automation, report the environment block instead of claiming a pass.

The Debug Simulator-only `--presentation-fixture` launch argument renders synthetic task and catalog content without activating WatchConnectivity, recording, or contacting a Mac. It remains visibly offline; it is not a connection or microphone test. Review at least the 40 mm layout and large text before changing the home footer. Never ship a production transport bypass for previews.

### Home layout constraints

- The home destination uses a two-line title. The picker's selected section wraps the full title and workspace for scrolling; retaining the complete text only in accessibility labels is insufficient.
- Keep the pinned recording control at least 48 points tall, with its brief cue inside the control. Full voice status belongs to a button at least 44 points tall in the scrolling content, with a working return to home.
- Expose the hold control as one accessibility button with start, finish, cancel, and status actions. Respect the system Reduce Motion preference.
- Start automated scrolling in the visible content above the pinned recording control. A whole-screen swipe can be captured by hold-to-record and is not a substitute for testing content scrolling.
- Check default and large text: reachable entries, no recording-control overlap with the destination, no unexpected keyboard, and repeated dismissal. Element-existence assertions do not replace screenshots and control-boundary checks.

See [signing](signing.md) for native device installation, renewal, and why LiveContainer is not a supported substitute for the watchOS companion chain.

## Changing actions

Adding or changing an action requires at least:

1. `WatchActionKindWire` and profile validation.
2. iPhone category, title, editor, and default mapping.
3. Mac `WatchActionEngine` execution.
4. The bridge custom-application allowlist boundary.
5. Single, double, long-press, and profile revision tests.
6. Chinese and English API, configuration, and usage documentation.

Do not add arbitrary shell execution. Application launch must remain an explicit bridge selection referenced through an internal profile ID.

## Changing protocols

LAN, relay, and profile currently use versions 7, 3, and 1. A protocol change must:

- keep old-endpoint compatibility through optional fields, or explicitly increment the corresponding version;
- update Swift sender, Swift receiver, TypeScript relay validation, and cross-language fixtures;
- test wrong version, missing and oversized fields, replay, expiry, direction, and ordering;
- preserve “no offline button queue,” “no partial-audio replay,” and “no late execution after reconnect”;
- update both API documents.

A local UI copy or layout change should not modify the wire schema without a real protocol need.

## Changing the relay

The current personal build excludes Relay with two independent gates. Work in this section applies only to a separately reviewed relay-capable variant; do not change either private-only gate as part of ordinary feature or connectivity work.

- One Durable Object represents one room; do not route all deployments through a global object.
- Use constructor `blockConcurrencyWhile` for schema initialization only, never across external I/O.
- Hash tokens before persistence and never write ciphertext to storage.
- Use WebSocket hibernation and attachments to recover connection role.
- Validate method, path, content type, length, time, and shape before routing input.
- Keep the stable JSON error shape and add Workers-runtime tests for new errors.
- Never add a real account, route, or secret to `wrangler.jsonc`.

## Changing Codex integration

- Keep the hook loopback-only and bearer-authenticated.
- Do not weaken header/body limits or constant-time token comparison.
- Test `UserPromptSubmit`, `Stop`, duplicate, and out-of-order behavior.
- New tasks must use independent `thread/start` with no parent/fork field, become existing targets, and keep voice disabled until registration succeeds.
- Codex voice must preserve original Watch PCM until first-party online transcription: acknowledge packets only after Mac delivery, write only to the Bridge-owned `0700` directory as a `0600` WAV, use the signed-in Codex account, revalidate the target, and queue returned text over initialized app-server stdin/stdout. Never log audio, paths, authentication, or transcripts, and never automatically replay an ambiguous submission.
- Missing acknowledgement, target change, cancellation, or disconnect must fail closed, remove partial audio, and never auto-replay. Finalized files are removed after the app-server call; scoped stale cleanup remains a recovery backstop, not normal retention.
- Keep Speech recognition and temporary pasteboard use confined to foreground dictation.
- Never place hook tokens, real tasks, paths, transcripts, or audio in fixtures, logs, or ledgers.
- Do not regress app-server input to argv, shell interpolation, or logs.

## Dependencies and generated files

- The relay is locked by `package-lock.json`; tests and deployment reinstall with `npm ci` instead of trusting an existing `node_modules` directory.
- Do not commit `node_modules`, `.wrangler`, or generated Worker types.
- Xcode projects are generated from `project.yml`; do not hand-maintain `project.pbxproj`.
- Record license, purpose, exact version, and distribution status for every dependency.
- Do not copy unlicensed icons, screenshots, audio, fonts, or third-party code.

## Documentation

Developer-visible changes must update both `docs/zh-CN` and `docs/en`. Both languages need the same file set, heading hierarchy, commands, versions, limits, and security disclosures. Translation must not omit risk information.

## License

The repository is GPL-3.0-only. A contributor must have the right to provide work under that license. Verify provenance and license compatibility before copying or adapting third-party implementations, and update `THIRD_PARTY_NOTICES.md`. Unclear code or asset rights block release.
