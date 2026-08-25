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
- [ ] Relay documents state per-developer self-hosting, outbound-only Mac Internet transport, and Cloudflare-visible metadata.
- [ ] Documentation contains no real configuration, path, screenshot, or historical acceptance claim.

## 5. Automated verification

```bash
make doctor
make test
make build
make security
git status --short
```

- [ ] Shared Swift tests pass.
- [ ] Bridge XCTest passes.
- [ ] Relay type generation, type checking, Vitest, and high-severity npm audit pass.
- [ ] iOS/watchOS Simulator and unsigned macOS builds pass.
- [ ] CI receives no Apple, Cloudflare, relay, or Keychain production secret.
- [ ] GitHub Actions use least privilege and pin third-party actions to full commit SHAs.
- [ ] The working tree contains only expected changes; ignored files were not force-added.

## 6. Device and runtime acceptance

- [ ] A fresh install signs, installs, and launches with the developer's own Team.
- [ ] First-use six-digit pairing and rejection both behave correctly.
- [ ] Single, double, and long press are verified for all 12 buttons.
- [ ] Favorites, custom shortcuts, and custom application profile synchronization work.
- [ ] Haptic toggle, press/cancel gesture, and Reduce Motion behavior are correct.
- [ ] Chinese foreground dictation completes recording and final recognition, then immediately injects into the focused input.
- [ ] The previous pasteboard contents are restored approximately 450 ms after foreground injection; if the pasteboard changes in that interval, the bridge preserves the new contents instead of overwriting them.
- [ ] Codex completed task, summary, confirmed voice, submission, and receipt complete; a task change rejects an old reply.
- [ ] LAN preference, Internet failover, offline Mac, connectivity recovery, and LAN recovery match documentation.
- [ ] Buttons pressed offline are not executed after reconnect.
- [ ] Reconnect after app and Mac restart is verified.
- [ ] No unrelated application or input-device configuration is read, replaced, or intercepted.

Automation, builds, health checks, and agent actions do not replace these device outcomes. Mark every unexecuted item as unaccepted.

## 7. Private GitHub repository settings

- [ ] Repository visibility is private.
- [ ] Default branch is `main`, with branch protection and required CI.
- [ ] Secret scanning, push protection, Dependabot, and private vulnerability reporting are enabled. If the plan lacks a feature, retain local and CI gitleaks gates.
- [ ] Actions default to `contents: read` and never inject production secrets into pull requests.
- [ ] Initial delivery is source-only: no signed app, IPA, provisioning profile, certificate, or private release asset.
- [ ] GitHub Pages, public Wiki, and automatic public visibility are disabled.

## 8. Final gate before public visibility

- [ ] Repeat setup, test, build, and security from a clean clone.
- [ ] Scan complete remote history, not only the latest local working tree.
- [ ] Re-download any candidate source archive, scan it, unpack it, and review every file.
- [ ] Repository owner reviewed the final tree, documentation, license, threat model, and unresolved issues.
- [ ] Repository owner explicitly approved public visibility at this release point.

Visibility change must remain a separate manual action. Build, test, and release scripts must never convert a private repository to public automatically.
