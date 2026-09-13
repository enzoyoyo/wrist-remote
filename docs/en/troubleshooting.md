# Troubleshooting

[简体中文](../zh-CN/troubleshooting.md)

First classify the failure as build, signing, LAN/Tailscale, permission, voice, action profile, or Codex. The current personal build is private-only and has no public-Relay fallback. A received message is not proof of final action, audio, or text delivery.

## Baseline checks

```bash
make doctor
make test
make build
```

- Missing XcodeGen: install it, or rerun `make setup` when Homebrew is already available.
- Missing `Config/Local.xcconfig`: run `make setup`.
- Permissions are not `0600`: run `chmod 600 Config/Local.xcconfig`.
- Bundle prefix still contains `example`: replace it with a unique value you control.
- Old Node version: upgrade to Node.js 24 or newer to match CI.

## Device installation fails

Run the read-only preflight:

```bash
scripts/install-devices.command --dry-run
```

Common causes:

- Locked iPhone or Watch.
- Watch not paired with the target iPhone.
- Developer Mode disabled.
- Xcode has not completed device-support preparation.
- Multiple devices or Apple Development identities make selection ambiguous.
- Team ID and Bundle ID provisioning mismatch.

Set only the one-shot variable named by the script. Do not attach UDIDs, Team IDs, provisioning profiles, or raw command output to an issue.

## Watch says the Mac is disconnected

1. Confirm the bridge, iPhone app, and Watch app are all running.
2. Confirm Local Network permission for iPhone and bridge.
3. First connection requires approving the same six-digit code on both sides.
4. Check whether VPN, firewall, or guest Wi-Fi blocks Bonjour or client-to-client traffic.
5. If foreground recovery is limited because iPhone was force-quit or locked, open the iPhone app.
6. For remote private access, confirm that Tailscale is active on the Mac and iPhone and that the saved endpoint is a literal official-range Tailscale IP. DNS names and public endpoints are rejected.

Transport recovery alone is not action success. Test a non-destructive mapping and observe the final Mac action.

## Connected but buttons do nothing

- Wait for iPhone to show that the current profile revision synchronized. The Mac does not execute an uninstalled revision.
- Grant Accessibility to the bridge.
- Add a custom application in the bridge before selecting its profile on iPhone.
- A custom shortcut needs a supported Control, Option, Shift, or Command modifier combination and a valid key code.
- Verify single, double, and long press separately; one passing gesture does not prove all three.

## No haptic feedback

- Check the Watch app's button-haptics setting.
- Check watchOS haptic settings and wearing state.
- Confirm the gesture committed. Dragging away or cancelling should not emit success feedback.
- Reduce Motion reduces visual animation but should not automatically disable semantic haptics.

## Chinese foreground dictation is not recognized

1. Grant Watch Microphone and Mac Speech Recognition permissions.
2. Confirm the bridge is connected and no other Watch voice session owns the stream.
3. Confirm the Mac offers a Chinese Speech recognizer. Simplified Chinese resolves preferentially to `zh-CN`; Traditional Chinese uses the matching region.
4. End recording normally and wait for the final result rather than relying on a partial transcript.
5. Completed foreground dictation is injected immediately into the focused input.
6. If recognition succeeds but no text appears, confirm the target input still has focus and check bridge Accessibility permission.

Only foreground dictation uses the bridge Speech framework and temporary pasteboard. It does not depend on a third-party input method, virtual microphone, or global Fn mode.

Foreground injection briefly uses the general system pasteboard and simulates Command-V. After approximately 450 ms, the previous contents are restored only if the pasteboard still contains the temporary transcript and has not changed; other processes may observe the text briefly. If another process changes the pasteboard, the bridge preserves the new contents and the original contents may not be restored automatically.

## A Relay route appears in a private-only build

Stop acceptance. A personal build must have `WRISTREMOTE_PRIVATE_ONLY = YES` and an `.invalid` Relay endpoint compiled into every product. Remove any historical Relay credentials through the documented private-only revocation path, restart all endpoints, and verify through system network state or packet capture that no request reaches a former public endpoint. Do not replace the `.invalid` value to work around a connection problem.

## Codex task is absent

1. Open the bridge and confirm hook state is ready.
2. Confirm the bridge has launched once and created its Keychain token.
3. Confirm hook configuration uses the actual absolute path to this clone's script.
4. Merge only `UserPromptSubmit` and `Stop`, then reload Codex configuration.
5. If `scripts/codex-notify.sh` reports local configuration failure, verify that the Bundle prefix matches the current bridge build.
6. HTTP 401 means token mismatch; 422 means invalid hook fields.
7. The first valid hook pins its thread; another thread does not take over automatically. To switch, click **Switch to next chat** in the Mac bridge, then cause the target thread to emit its next hook event.

Do not paste a hook token, real task JSON, working directory, or transcript into a public issue.

## Codex reply fails

- The target must be the exact selected, authorized existing task. Running-state and revision checks still apply to the operation being attempted.
- A newly requested task must first complete an independent `thread/start` with no parent/fork relationship, appear as an existing target, and only then accept voice.
- Refresh **Choose conversation** on the Watch and verify that the target authorization is unexpired and still accepts input.
- The Codex executable must be executable. If discovery fails, configure its local absolute path and rebuild the bridge.
- The local Codex app-server must answer `thread/list`, independent `thread/start`, and text `thread/queue/add` requests within the bounded timeout. Voice also requires a signed-in Codex account and access to its online transcription service.
- Reusing a submission ID with different content is rejected.

Codex voice does not use macOS Speech or the pasteboard. The Watch sends original PCM through iPhone; while the connection remains live, it advances to the next packet only after the Mac acknowledges the current packet. The Mac writes an owner-only temporary WAV, requests first-party online transcription with the signed-in Codex account, revalidates the destination, and queues the text through local app-server. If an acknowledgement is missing, the route disconnects, or the target changes, the stream fails closed, partial audio is deleted, and nothing is replayed automatically. Record again after reconnecting; if a submission result is uncertain, first inspect the selected task to avoid sending twice.

## Collect diagnostics safely

Safe fields include affected component, source version, operating-system major version, sanitized reproduction steps, expected/actual state, and sanitized error code.

Remove names, email, real domains, IP addresses, room IDs, device IDs, UDIDs, Team IDs, Bundle prefixes, tokens, E2E keys, paths, task content, transcripts, screenshots, provisioning profiles, and full logs before sharing.

Use GitHub private vulnerability reporting for security issues. Do not disclose exploit details publicly.
