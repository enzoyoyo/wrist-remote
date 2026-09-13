# Configuration reference

[简体中文](../zh-CN/configuration.md)

## Configuration precedence

1. `Config/WristRemote.xcconfig`: tracked safe defaults.
2. `Config/Local.xcconfig`: ignored developer overrides; keep mode `0600`.
3. Apple Keychain: the Mac and iPhone installation identities, the iPhone's pinned Mac fingerprint and validated Tailscale IP, the Mac's trusted iPhone fingerprints, and the hook token.
4. Relay credentials exist only for a separately reviewed relay-capable variant. They are outside the active personal-build boundary.
5. One-shot environment variables: only for device, Team, or install-target disambiguation.

Do not place runtime secrets in xcconfig files, `.env`, Wrangler configuration, command arguments, screenshots, or issue reports.

## Xcode settings

| Variable | Required | Meaning |
|---|---:|---|
| `WRISTREMOTE_BUNDLE_PREFIX` | For devices | A unique reverse-domain identifier you control; provides safe defaults for new mobile, bridge, and test Bundle IDs |
| `WRISTREMOTE_IOS_BUNDLE_IDENTIFIER` | No | Exact iPhone app Bundle ID; defaults to `$(WRISTREMOTE_BUNDLE_PREFIX).ios` and is overridden only for a verified in-place upgrade |
| `WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER` | No | Exact Watch app Bundle ID; defaults under the iPhone ID's `.watchkitapp` namespace and must exactly match the installed Watch app |
| `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` | No | Explicit Mac Bridge Bundle ID override for a reviewed in-place upgrade; defaults to `$(WRISTREMOTE_BUNDLE_PREFIX).bridge` |
| `WRISTREMOTE_EXISTING_INSTALL_REQUIRED` | No | Defaults to `NO`; set to `YES` for a controlled mobile upgrade that requires an exact existing app on both devices |
| `WRISTREMOTE_DEVELOPMENT_TEAM` | For devices | Your ten-character Apple Team ID, used only for local signing |
| `WRISTREMOTE_PRIVATE_ONLY` | Personal build | Must be `YES`; disables public Relay at build/configuration level |
| `WRISTREMOTE_RELAY_BASE_URL` | Private-only build | Must remain an HTTPS URL under the reserved `.invalid` top-level domain; this is the second public-Relay exclusion gate |
| `WRISTREMOTE_CODEX_EXECUTABLE_PATH` | No | Custom Codex executable path; blank enables safe bridge discovery |

Regenerate or rebuild affected apps after changing xcconfig. A personal build is acceptable only when both Relay gates are present: `WRISTREMOTE_PRIVATE_ONLY = YES` and an `.invalid` Relay URL compiled into the products.

## One-shot environment variables

| Variable | Consumer | Meaning |
|---|---|---|
| `WRIST_DEVELOPER_DIR` | Device install | Explicitly selects one Xcode Developer directory for this invocation without changing global `xcode-select`; pre-release Xcode is allowed only through this override |
| `WRIST_TEAM_ID` | Device install | Resolves multiple Apple Teams |
| `WRIST_IPHONE_UDID` | Device install | Resolves multiple iPhones |
| `WRIST_WATCH_UDID` | Device install | Resolves multiple Watches |
| `WRIST_CODESIGN_IDENTITY` | Mac build | Selects one exact valid local Apple Development identity when automatic selection is ambiguous |
| `WRISTREMOTE_INSTALL_DIR` | Mac install | Replaces the current user's Applications directory |
| `WRISTREMOTE_RELAY_BASE_URL` | Relay deployment | Supplies the HTTPS URL when Wrangler output cannot be detected |

Environment values can be visible to same-user processes. Set them only when needed, clear them afterward, and do not add them to shell startup files.

### Mac build signing selection

`make install-mac` and `scripts/build-macos.sh` inspect valid local code-signing identities without printing or persisting their certificate names, hashes, or Team IDs:

1. A non-empty `WRIST_CODESIGN_IDENTITY` must exactly match one valid local `Apple Development` identity by full certificate hash or full common name. An invalid, non-development, or ambiguous match stops the build.
2. Without an override, exactly one valid `Apple Development` identity is selected automatically. This gives repeated local installs a stable signature.
3. If more than one valid `Apple Development` identity exists, the build stops instead of guessing.
4. Ad-hoc signing is used only when no valid `Apple Development` identity exists. Setting `WRIST_CODESIGN_IDENTITY=-` to force ad-hoc signing is rejected.

The selected identity is kept only in the build process memory and passed directly to `codesign`; the script's status and error messages never include identity details. This is still a local development install, not a Developer ID notarized distribution.

## Bundle IDs and Keychain

The Bundle prefix must be unique and must not retain an `example` placeholder. Keychain services derive from the final Bundle ID or prefix and cover:

- iPhone and Watch installation identity and the private-only Relay-revocation marker;
- iPhone private-network endpoint configuration;
- Mac long-term P-256 server identity, iPhone pinned-Mac fingerprint, and Mac trusted-iPhone fingerprints;
- bridge private-only Relay exclusion/revocation state;
- bridge Codex hook bearer token.

Changing the Bundle prefix or either final Bundle ID creates a separate installation identity. Keychain items, preferences, pinned fingerprints, and pairing state are not migrated automatically, and a second app may appear on the device.

### Controlled iPhone and Watch in-place upgrade

Only after independently confirming the exact existing identities from signed artifacts, valid provisioning profiles, and the live device inventory, set `WRISTREMOTE_IOS_BUNDLE_IDENTIFIER`, `WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER`, and `WRISTREMOTE_EXISTING_INSTALL_REQUIRED = YES` together in ignored `Config/Local.xcconfig`. Never copy those machine-specific values into tracked configuration.

Both `scripts/install-devices.command --dry-run` and the actual installer verify that the Watch ID is strictly derived from the iPhone ID, neither ID is a placeholder, the current Apple Development Team matches historical profile identities (newly built profiles must be unexpired), and the connected iPhone and Watch contain the exact existing identities. A same-named app with another ID, unreadable device inventory, profile mismatch, or missing reviewed installation stops the run. After the signed build completes, the installer reads both devices again as the final pre-write identity gate.

These overrides affect only the mobile targets. Keep `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` independently pinned to the currently installed bridge identity so its Bundle-derived Keychain service and long-term server key do not change.

### Controlled Mac Bridge upgrade

`make install-mac` installs to the default per-user location. To upgrade a verified Bridge at another location, use:

```bash
scripts/build-macos.sh --install --target-app /absolute/path/WristRemoteBridge.app
```

The target must be an absolute, non-symlinked `.app` path. The installer compares the existing target's readable Bundle ID with the verified build product and refuses a mismatch. If a deliberate legacy target does not use the prefix-derived default, set `WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER` in ignored `Config/Local.xcconfig` only after independently confirming the intended target and its Bundle ID.

Before building, before replacement, and before opening the result, the installer checks for every running process named `WristRemoteBridge`, including the target itself. It fails closed if any such process is running or cannot be resolved to an exact app path. It never sends a termination signal; quit every Bridge normally, then retry. This prevents a second Bridge from retaining or racing for TCP `60927` while the intended app is replaced.

## Public-Relay exclusion

The current personal build does not deploy or use a public Relay. Keep both independent gates enabled:

1. `WRISTREMOTE_PRIVATE_ONLY = YES` in the build configuration.
2. `WRISTREMOTE_RELAY_BASE_URL` under the reserved `.invalid` top-level domain.

A non-`.invalid` endpoint must not be added merely to make a remote connection work. Relay-capable source, deployment notes, or tests do not make Relay part of this build. Enabling it would require a separate security review, build, provisioning flow, and real-device acceptance decision.

## Local ports and services

| Interface | Address | Purpose |
|---|---|---|
| LAN bridge | `_wristremote._tcp`, TCP `60927` | Dedicated iPhone-to-Mac pairing and encrypted protocol |
| Tailscale bridge | One concrete Tailscale `utun` address, TCP `60927` | Optional private-network fallback using the same pairing and encrypted protocol |
| Codex hook | `127.0.0.1:60928/codex-hook` | Bearer-authenticated local task events |
| Relay | Disabled | Excluded by the private-only build flag and `.invalid` endpoint |

Do not expose ports `60927` or `60928` through router port forwarding, Tailscale Funnel, a public proxy, or a public wildcard listener.

## Tailscale private-network configuration

Private-network mode is runtime configuration, not an xcconfig value:

1. The Mac Bridge stores an independent `tailnetAccessEnabled` preference. It defaults to `false` and never changes the LAN listener.
2. When enabled, the bridge looks only for a concrete `utun` address in Tailscale's official `100.64.0.0/10` or `fd7a:115c:a1e0::/48` ranges and starts a separate listener on fixed TCP `60927`.
3. The iPhone stores an enabled flag plus the validated host in its own Keychain service. The host must be a literal IP in Tailscale's official IPv4 or IPv6 range. DNS names (including MagicDNS), URLs, paths, credentials, arbitrary ports, public IPs, and unrelated private IPs are rejected.
4. The iPhone gives Bonjour a 0.9-second head start. If no LAN candidate is ready and adopted by then, it also starts the private endpoint candidate; first-ready wins and cancels the other candidate. An adopted route is not preempted, and the next reconnect cycle starts LAN-first again. LAN failure or timeout starts the private candidate immediately.
5. Mutual installation-identity verification, two-ended first approval, transcript-bound session-key negotiation, and frame encryption are identical on LAN and Tailscale routes.

Use [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand) to control iPhone tunnel activation and a least-privilege [Grant](https://tailscale.com/docs/features/access-control/grants) limited to the intended source and `tcp:60927` on the Mac. Enter the Mac's official Tailscale IP directly; do not use MagicDNS, Funnel, router port forwarding, or a public proxy. Full setup and acceptance steps are in [tailscale-private-network.md](tailscale-private-network.md).

The Watch does not receive or store the Tailscale endpoint. It sends live commands to the paired iPhone through Watch Connectivity, and the iPhone owns both direct routes. Independent-cellular use with no reachable iPhone is intentionally unavailable in the current private-only build; it does not fall back to a public Relay.

## Direct-pairing identity lifecycle

- The Mac creates one long-term P-256 signing identity only when its dedicated Keychain item is absent. A locked, unavailable, or corrupt item stops both direct listeners; it is not silently replaced.
- The iPhone follows the same fail-closed rule for its long-term P-256 client identity: it creates a key only when the dedicated item is absent. A locked, unreadable, or corrupt item blocks connection rather than silently replacing the identity.
- The iPhone verifies the Mac's signature before showing trust UI. On first use it requires local approval, sends a client identity proof bound to that Mac and the current ephemeral exchange, and stores the Mac fingerprint only after the Mac has also approved the session.
- The Mac stores the approved iPhone installation fingerprint in its own Keychain and auto-reconnects only when the client reports that it has already pinned this Mac. If that Keychain write fails, the Mac sends a denial and never marks the session ready. This makes an upgrade from the earlier one-way trust flow require one explicit two-ended pairing.
- A stored Mac-fingerprint mismatch, unavailable iPhone trust store, invalid signature, or incomplete handshake fails closed. Updating the saved official Tailscale IP for the same verified Mac does not by itself replace or reset the pinned Mac identity.
- If the intended Bridge was deliberately reinstalled under a new identity, first verify that change outside the app. Then choose **Forget trusted Mac** on the iPhone and complete the two-ended six-digit pairing again. The action deletes only the iPhone's pinned Mac fingerprint; it does not alter the endpoint or mappings.
- Use **Reset this iPhone's pairing identity** only when its identity item is known to be damaged or a new client identity is deliberately required. The destructive action has a separate confirmation, does not change mappings or other remotes, and causes the Mac to treat the app as a new iPhone that must be approved again.

## Action configuration

The iPhone manages a complete 12-button × 3-gesture profile. Actions include basic keys, arrows, copy/paste/quit, Show Desktop, context menu, app switching, volume/media, custom shortcuts, and custom applications selected in the bridge.

A custom application uses a bridge-generated internal profile ID. The iPhone does not receive an arbitrary file path or Bundle ID. After deleting or replacing a Mac application profile, wait for the latest profile revision to synchronize before testing.

## Permissions

- Watch Microphone: capture only after explicit voice interaction.
- iPhone/bridge Local Network: Bonjour and LAN transport.
- Tailscale VPN on iPhone and Mac: optional private-network route; controlled in the Tailscale app and operating system, not by Wrist Remote.
- Bridge Accessibility: button actions and foreground-dictation text injection.
- Bridge Speech Recognition: system Speech framework for foreground dictation only.
- Launch at Login: an explicit user choice in the bridge, not a build-script side effect.

Denied permissions cause an explicit feature failure; the project does not fall back to another application or global input pipeline.

Foreground dictation uses the system Speech framework and general pasteboard to simulate Command-V. Recognized text is briefly present on the pasteboard and the previous contents are restored after approximately 450 ms only if no other process changed it. Do not use this path to inject passwords, tokens, or other secrets; disable foreground dictation when any shared-pasteboard exposure is unacceptable.

Codex task voice is a separate path: the Watch records PCM, the Mac writes an owner-only temporary WAV, and the Bridge uses the signed-in Codex account for first-party online transcription. After revalidating the selected target, it queues the returned text through local app-server. This requires Internet access, not macOS Speech permission, and does not use the pasteboard. A new task must first complete an independent `thread/start` with no parent/fork relationship and become an existing target before voice is enabled. Temporary audio is deleted when processing finishes, on cancellation, or after a stream disconnect; a broken stream fails closed and is never replayed automatically.
