# Private installation and signing

Wrist Remote uses a native iPhone/watchOS companion pair and an independent Mac Bridge. Build, automated checks, signing, and physical-device acceptance are separate gates.

## Before connecting devices

With full Xcode, simulator runtimes, and dependencies configured:

```sh
make verify
```

This checks repository privacy, tests, dependencies, simulator interaction, and unsigned builds. It does not install on physical devices. Passing does not validate physical microphones, haptics, or off-LAN connectivity.

## When devices are available

1. Unlock the iPhone and Watch; enable Developer Mode and approve system pairing.
2. Sign in to Xcode with your own Apple account. Keep certificates in the local keychain.
3. Run `scripts/install-devices.command --dry-run` for read-only preflight.
4. Confirm the intended targets, then run `make install-devices`. The script validates bundle IDs, Team, and existing installation identity before upgrading in place. It never deletes apps by display name.
5. Validate Chinese audio, cancellation, destination selection, independent task creation, reconnects, and the private Tailscale path on actual devices.

Free Personal Team provisioning profiles expire seven days after issuance and require rebuilding/reinstalling. Paid signing is also subject to certificate and profile expiry. See [Apple's account guide](https://developer.apple.com/help/account/basics/about-your-developer-account).

For controlled upgrades, when `ideviceinstaller` is available, the installer reads the iPhone app's exact signed bundle and Team identity directly. This avoids depending on historical provisioning caches that Xcode may remove; mismatches still stop installation. If the selected Watch has no existing app, explicitly use `scripts/install-devices.command --allow-watch-first-install` to allow only its first installation. The iPhone upgrade gate and all new-build signature/device checks remain active. Never change the Team or disable upgrade requirements to bypass a failure.

## LiveContainer assessment

LiveContainer is not the supported installation route for this project. It runs iOS guests inside a host rather than replacing the native watchOS companion installation chain. Its [FAQ](https://livecontainer.github.io/docs/faq) notes that guests generally cannot use extensions requiring additional App IDs. The [official repository](https://github.com/LiveContainer/LiveContainer) warns about sensitive guest data access by third-party builds.

Apple's [WatchConnectivity sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) requires native target signing and companion bundle identity configuration. Based on these constraints, this project retains native signing and isolation. This is a compatibility/risk assessment, not a claim of LiveContainer device testing.

Never disable Gatekeeper, export signing private keys, upload Apple credentials/profiles, or import pairing credentials into a third-party container.
