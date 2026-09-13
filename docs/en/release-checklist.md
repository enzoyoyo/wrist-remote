# Release checklist

[简体中文](../zh-CN/release-checklist.md)

Keep the initial repository private. Public visibility can be considered only after every gate below passes and the repository owner explicitly approves it. A private repository is not a secret store.

## 1. Content scope

- [ ] The repository contains only Wrist Remote clients, bridge, relay, generic tooling, examples, and public developer documentation.
- [ ] No `.git` history, bug records, research/plans, internal discussion, conversations, process logs, or private acceptance evidence were imported from a working repository.
- [ ] No DerivedData, `.build`, `build`, Generated, Xcode user data, `node_modules`, `.wrangler`, cache, or temporary files.
- [ ] No user photos, real-device screenshots, recordings, private tasks, or local diagnostic bundles.
- [ ] Generated files can be recreated with `make setup` and `make build`.

## 2. Privacy and secrets

- [ ] `make security` passes.
- [ ] gitleaks scans the working tree and complete Git history with zero findings.
- [ ] `git ls-files` has been reviewed manually, file by file.
- [ ] No names, email addresses, real domains, IPs, accounts, device names, device IDs, UDIDs, Team IDs, or local absolute paths.
- [ ] No token, cookie, API key, certificate, private key, provisioning profile, Keychain export, `.env`, `.dev.vars`, or production xcconfig.
- [ ] Image metadata and binary strings contain no EXIF, path, or signing identity.
- [ ] Examples use explicit placeholders or TEST_ONLY data, not realistic secrets disguised as examples.
- [ ] Git commit authors use an approved organization identity or noreply address.

Scanner reports must not copy matched secret values. Record only repository-relative file, category, and pass/fail status.

## 3. License and provenance

- [ ] `LICENSE` clearly states GPL-3.0-only.
- [ ] Contributors have the right to license every code and asset contribution under GPL-3.0-only.
- [ ] No content was copied from unknown, incompatible, or non-redistributable sources.
- [ ] `THIRD_PARTY_NOTICES.md` agrees with direct dependencies in lockfiles.
- [ ] App icon and other asset grants are complete and contain no third-party trademark artwork.
- [ ] New dependencies passed license compatibility and supply-chain review.

Unclear license or provenance blocks release even while the repository is private.

## 4. Documentation

- [ ] README, SECURITY, PRIVACY, contribution guides, and `docs/zh-CN` / `docs/en` agree.
- [ ] Both languages have the same files, protocol versions, commands, limits, and risk disclosures.
- [ ] All internal links resolve.
- [ ] Installation documents state that Apple sign-in, trust, Developer Mode, and permission prompts require user action.
- [ ] Private-only documents require `WRISTREMOTE_PRIVATE_ONLY = YES`, an `.invalid` Relay endpoint, literal official-range Tailscale IPs, and no Funnel, public listener, or public fallback. Relay-development documents are clearly outside that active build boundary.
- [ ] Documentation contains no real configuration, path, screenshot, or historical acceptance claim.

## 5. Automated verification

```bash
make doctor
make verify
git status --short
```

`make verify` includes the high-severity relay dependency audit and iOS/watchOS Simulator tests. It must fail rather than skip when compatible Simulator runtimes are absent.

- [ ] Shared Swift tests pass.
- [ ] Bridge XCTest passes.
- [ ] Relay type generation, type checking, Vitest, and high-severity npm audit pass.
- [ ] iOS/watchOS Simulator and unsigned macOS builds pass.
- [ ] CI receives no Apple, Cloudflare, relay, or Keychain production secret.
- [ ] GitHub Actions use least privilege and pin third-party actions to full commit SHAs.
- [ ] The working tree contains only expected changes; ignored files were not force-added.

## 6. Device and runtime acceptance

- [ ] A fresh install signs, installs, and launches with the developer's own Team.
- [ ] A controlled upgrade uses both verified exact mobile Bundle IDs; `--dry-run` confirms the current Team, historical profile identities (newly built profiles must be unexpired), and live identities on both devices, while the Bridge Bundle ID remains unchanged.
- [ ] First-use six-digit pairing and rejection both behave correctly.
- [ ] Single, double, and long press are verified for all 12 buttons.
- [ ] Favorites, custom shortcuts, and custom application profile synchronization work.
- [ ] Haptic toggle, press/cancel gesture, and Reduce Motion behavior are correct.
- [ ] Chinese foreground dictation completes recording and final recognition, then immediately injects into the focused input.
- [ ] The previous pasteboard contents are restored approximately 450 ms after foreground injection; if the pasteboard changes in that interval, the bridge preserves the new contents instead of overwriting them.
- [ ] Codex conversation listing, search, destination selection, and independent new-task creation work; `thread/start` contains no parent/fork relationship, the result becomes an existing target, and voice remains disabled until then.
- [ ] Held Codex voice sends original Watch PCM; the Mac creates an owner-only temporary WAV, uses the signed-in Codex account for first-party online transcription, revalidates the exact target, and queues text through local app-server. No macOS Speech or clipboard is used; temporary audio is deleted after processing, cancellation, or stream disconnect.
- [ ] During one live audio stream, each packet advances only after Mac acknowledgement. A missing acknowledgement or disconnect fails closed, deletes partial audio, and never replays it automatically; the user must record again.
- [ ] With `WRISTREMOTE_PRIVATE_ONLY = YES` and the relay URL set to `.invalid`, the Mac, iPhone, and Watch remove historical relay credentials; revocation survives a restart and an uninstall/reinstall that retains Keychain items, and packet capture or system network state confirms that no request reaches an old public endpoint.
- [ ] LAN preference, official-IP-only Tailscale failover, offline Mac, connectivity recovery, and LAN recovery match documentation; DNS, Funnel, public IP, and public fallback are rejected.
- [ ] Buttons pressed offline and partial voice streams are not executed or replayed after reconnect.
- [ ] Reconnect after app and Mac restart is verified.
- [ ] No unrelated application or input-device configuration is read, replaced, or intercepted.

Automation, builds, health checks, and agent actions do not replace these device outcomes. Mark every unexecuted item as unaccepted.

## 7. Private GitHub staging

- [ ] Repository visibility is private.
- [ ] Default branch is `main`; the exact candidate commit has passed `Privacy, secrets, and history`, `Relay checks`, and `Apple builds and tests` in private CI.
- [ ] Actions default to `contents: read` and never inject production secrets into pull requests.
- [ ] Initial delivery is source-only: no signed app, IPA, provisioning profile, certificate, or private release asset.
- [ ] GitHub Pages, public Wiki, and automatic public visibility are disabled.
- [ ] A fresh clone from the private remote passes the repository security gate and all locally supported tests and unsigned builds.

CodeQL jobs intentionally skip while the repository is private unless the account has the required GitHub Code Security entitlement. Do not claim CodeQL coverage and do not make CodeQL a required check at this stage. Keep local and CI gitleaks gates active.

## 8. Public transition and post-public security

- [ ] Repeat setup, test, build, and security from a clean clone.
- [ ] Scan complete remote history, not only the latest local working tree.
- [ ] Re-download any candidate source archive, scan it, unpack it, and review every file.
- [ ] Repository owner reviewed the final tree, documentation, license, threat model, and unresolved issues.
- [ ] Repository owner explicitly approved public visibility at this release point.
- [ ] Change visibility to public as a separate repository-owner action, then verify unauthenticated access and the `main` default branch.
- [ ] Manually dispatch CodeQL for the public commit and require both `JavaScript and TypeScript` and `Swift` to succeed.
- [ ] Enable secret scanning, push protection, Dependabot security updates, and private vulnerability reporting where GitHub exposes them for the public repository.
- [ ] Only after the successful CI and CodeQL check runs exist, configure `main` branch protection using their actual check-run names and read the protection back from GitHub.
- [ ] Confirm that no Release, deployment, Pages site, signed binary, provisioning profile, certificate, or private acceptance artifact was published.

Visibility change must remain a separate repository-owner action. Build, test, and release scripts must never convert a private repository to public automatically. Branch protection must not require a check that has never completed successfully for the public commit.
