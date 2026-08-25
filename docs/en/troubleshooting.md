# Troubleshooting

[简体中文](../zh-CN/troubleshooting.md)

First classify the failure as build, signing, LAN, relay, permission, voice, action profile, or Codex. A received message is not proof of final action or text delivery.

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
6. Relay fallback works only after deployment, rebuilding all endpoints, and provisioning.

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

## Chinese speech is not recognized

1. Grant Watch Microphone and Mac Speech Recognition permissions.
2. Confirm the bridge is connected and no other Watch voice session owns the stream.
3. Confirm the Mac offers a Chinese Speech recognizer. Simplified Chinese resolves preferentially to `zh-CN`; Traditional Chinese uses the matching region.
4. End recording normally and wait for the final result rather than relying on a partial transcript.
5. Completed foreground dictation is injected immediately into the focused input. Only Codex task voice uses draft confirmation, and it additionally requires the current completed task identity.
6. If recognition succeeds but no text appears, confirm the target input still has focus and check bridge Accessibility permission.

This path uses the bridge Speech framework. It does not depend on a third-party input method, virtual microphone, or global Fn mode.

Foreground injection briefly uses the general system pasteboard and simulates Command-V. After approximately 450 ms, the previous contents are restored only if the pasteboard still contains the temporary transcript and has not changed; other processes may observe the text briefly. If another process changes the pasteboard, the bridge preserves the new contents and the original contents may not be restored automatically.

## Relay health fails

- HTTP 503 with `configured=false`: `ALLOWED_ROOM_ID` or `BOOTSTRAP_MAC_TOKEN` is missing or malformed. Rerun `make deploy-relay`.
- `mac_offline`: Worker is healthy but has no active bridge WSS. Open the bridge and confirm the same relay URL and Keychain credentials.
- `unauthorized`: the device or Mac bearer does not match initialized room credentials. Do not repeatedly hand-initialize the room.
- `replay_detected`: a sequence or operation ID was reused; create a new operation.
- `relay_timeout`: a bridge connection exists but did not answer within 15 seconds. Check bridge state and network.
- Health passes but Watch has no Internet path: rebuild all endpoints after deployment and complete one LAN provisioning session.

The relay intentionally does not preserve offline buttons. No late execution after reconnect is correct behavior.

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

- The task must be the exact current completed task. Running, changed, and old-revision tasks are rejected.
- The user must confirm a non-empty draft.
- `session_id` must be a usable thread UUID.
- The Codex executable must be executable. If discovery fails, configure its local absolute path and rebuild the bridge.
- The CLI must accept the queue request within five seconds.
- Reusing a submission ID with different content is rejected.

## Collect diagnostics safely

Safe fields include affected component, source version, operating-system major version, sanitized reproduction steps, expected/actual state, and sanitized error code.

Remove names, email, real domains, IP addresses, room IDs, device IDs, UDIDs, Team IDs, Bundle prefixes, tokens, E2E keys, paths, task content, transcripts, screenshots, provisioning profiles, and full logs before sharing.

Use GitHub private vulnerability reporting for security issues. Do not disclose exploit details publicly.
