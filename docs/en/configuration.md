# Configuration reference

[简体中文](../zh-CN/configuration.md)

## Configuration precedence

1. `Config/WristRemote.xcconfig`: tracked safe defaults.
2. `Config/Local.xcconfig`: ignored developer overrides; keep mode `0600`.
3. Apple Keychain: installation identities, hook token, and the relay bearers and E2E credentials required by the Mac and iPhone/Watch clients.
4. Cloudflare Worker secret storage: long-term storage for the allowed room and `BOOTSTRAP_MAC_TOKEN`; the latter equals the client-side Mac bearer.
5. One-shot environment variables: only for device, Team, or install-target disambiguation.

Do not place runtime secrets in xcconfig files, `.env`, Wrangler configuration, command arguments, screenshots, or issue reports.

## Xcode settings

| Variable | Required | Meaning |
|---|---:|---|
| `WRISTREMOTE_BUNDLE_PREFIX` | For devices | A unique reverse-domain identifier you control; derives `.ios`, `.watchkitapp`, `.bridge`, and test Bundle IDs |
| `WRISTREMOTE_DEVELOPMENT_TEAM` | For devices | Your ten-character Apple Team ID, used only for local signing |
| `WRISTREMOTE_RELAY_BASE_URL` | For Internet mode | HTTPS relay root; the `.invalid` value safely disables Internet mode |
| `WRISTREMOTE_CODEX_EXECUTABLE_PATH` | No | Custom Codex executable path; blank enables safe bridge discovery |

Regenerate or rebuild affected apps after changing xcconfig. The relay URL is compiled into all three Info.plist files, so deploy then rebuild the Mac, iPhone, and Watch apps.

## One-shot environment variables

| Variable | Consumer | Meaning |
|---|---|---|
| `WRIST_DEVELOPER_DIR` | Device install | Selects one Xcode Developer directory without changing global `xcode-select` |
| `WRIST_TEAM_ID` | Device install | Resolves multiple Apple Teams |
| `WRIST_IPHONE_UDID` | Device install | Resolves multiple iPhones |
| `WRIST_WATCH_UDID` | Device install | Resolves multiple Watches |
| `WRIST_CODESIGN_IDENTITY` | Mac build | Replaces default ad-hoc signing |
| `WRISTREMOTE_INSTALL_DIR` | Mac install | Replaces the current user's Applications directory |
| `WRISTREMOTE_RELAY_BASE_URL` | Relay deployment | Supplies the HTTPS URL when Wrangler output cannot be detected |

Environment values can be visible to same-user processes. Set them only when needed, clear them afterward, and do not add them to shell startup files.

## Bundle IDs and Keychain

The Bundle prefix must be unique and must not retain an `example` placeholder. Keychain services derive from the final Bundle ID or prefix and cover:

- iPhone and Watch installation/relay provisioning;
- bridge relay credentials;
- bridge Codex hook bearer token.

Changing the Bundle prefix creates a separate installation identity. Keychain, preferences, and pairing state under the old prefix are not migrated automatically.

## Relay configuration

`apps/WristRemoteRelay/wrangler.jsonc` contains only the generic Worker, Durable Object binding, and migration. It has no Cloudflare account ID, real route, or secret. The default deployment uses the developer's own `workers.dev` endpoint and disables observability.

Two Worker secrets are required:

| Name | Source | Worker purpose |
|---|---|---|
| `ALLOWED_ROOM_ID` | Securely generated locally | Reject all other rooms before creating a Durable Object |
| `BOOTSTRAP_MAC_TOKEN` | Securely generated locally; equal to the client-side Mac bearer | Authenticate room initialization; the same bearer is checked against its DO hash afterward |

The Mac and iPhone/Watch clients store their role-specific device/Mac bearers and E2E credentials in Apple Keychain. Cloudflare edge processing handles Bearer headers during authentication, and Worker secret storage retains the two deployment secrets. Durable Object SQLite stores SHA-256 hashes of the Mac/device tokens, the randomly generated relay device UUID, initialization time, and replay, sequence, and rate-limit state. It stores no bearer plaintext, E2E key, ciphertext, or plaintext payload.

Disclosure of `BOOTSTRAP_MAC_TOKEN` lets an attacker impersonate the Mac at the relay authentication layer, occupy the connection, or cause denial of service. It does not permit payload decryption without the E2E key. Rotate secrets and reprovision immediately after disclosure.

## Local ports and services

| Interface | Address | Purpose |
|---|---|---|
| LAN bridge | `_wristremote._tcp`, TCP `60927` | Dedicated iPhone-to-Mac pairing and encrypted protocol |
| Codex hook | `127.0.0.1:60928/codex-hook` | Bearer-authenticated local task events |
| Relay | Developer-owned HTTPS URL | Optional public-network ciphertext transport |

Do not expose ports `60927` or `60928` through router port forwarding.

## Action configuration

The iPhone manages a complete 12-button × 3-gesture profile. Actions include basic keys, arrows, copy/paste/quit, Show Desktop, context menu, app switching, volume/media, custom shortcuts, and custom applications selected in the bridge.

A custom application uses a bridge-generated internal profile ID. The iPhone does not receive an arbitrary file path or Bundle ID. After deleting or replacing a Mac application profile, wait for the latest profile revision to synchronize before testing.

## Permissions

- Watch Microphone: capture only after explicit voice interaction.
- iPhone/bridge Local Network: Bonjour and LAN transport.
- Bridge Accessibility: button actions and foreground-dictation text injection.
- Bridge Speech Recognition: system Speech framework.
- Launch at Login: an explicit user choice in the bridge, not a build-script side effect.

Denied permissions cause an explicit feature failure; the project does not fall back to another application or global input pipeline.

Foreground dictation uses the general system pasteboard to simulate Command-V. Recognized text is briefly present on the pasteboard and the previous contents are restored after approximately 450 ms only if no other process changed it. Do not use this path to inject passwords, tokens, or other secrets; disable foreground dictation when any shared-pasteboard exposure is unacceptable. Codex task voice has a separate draft-confirmation flow and never submits an unconfirmed draft to Codex.
