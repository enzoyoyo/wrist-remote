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

Types under `apps/WristRemote/Shared` are not currently an external `public` API. Integrations should use the UI, Codex loopback hook, or relay HTTP/WSS surfaces and must not assume that another Swift package can directly import or construct these internal types.

## Common commands

```bash
make setup       # tools, Local.xcconfig, XcodeGen, and npm ci
make doctor      # read-only environment checks
make test        # Swift package, bridge XCTest, relay check
make relay-audit # high-severity audit of locked relay dependencies
make test-simulators # iOS XCTest and offline watchOS UI smoke tests
make build       # unsigned builds for all Apple targets
make security    # path, credential, and Git-history scan
make verify      # complete release gate, including audit and Simulator tests
make clean       # remove only explicit generated directories
```

`make setup` may install XcodeGen when Homebrew is already available, so it can change the development machine. `make doctor` installs and modifies nothing. Simulator runtime compatibility is checked by `make test-simulators` and the complete `make verify` gate, not by `make doctor`.

## Test layers

- Shared Swift tests: profile completeness, protocol shapes, connection state, relay crypto, and gesture resolution.
- Bridge XCTest: actions, pairing source restrictions, profile sessions, speech generations, Codex hook/reply, and isolation boundaries.
- Relay check: Wrangler type generation, two TypeScript type checks, and Workers-runtime Vitest.
- Simulator tests: the iOS XCTest target plus the two watchOS UI smoke tests that do not require a live bridge.
- Unsigned builds: iOS Simulator, watchOS Simulator, and macOS Release compilation.
- Connected/manual testing: the remaining watchOS UI tests require a live bridge; real-device checks cover pairing, permissions, all 36 mapping slots, haptics, Chinese voice, Codex receipts, LAN/WAN failover, and lifecycle reconnect.

The automated layers do not replace connected or real-device testing. If the operating system lacks the required Simulator runtimes or cannot enable UI automation, report the environment block instead of claiming a pass.

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
- preserve “no offline button queue” and “no late execution after reconnect”;
- update both API documents.

A local UI copy or layout change should not modify the wire schema without a real protocol need.

## Changing the relay

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
- Replies must continue to require user confirmation, the exact current completed task, and an idempotent submission ID.
- Never place hook tokens, real tasks, paths, or transcripts in fixtures.
- If the CLI moves to stdin, update the threat model to remove or revise the current process-argument risk.

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
