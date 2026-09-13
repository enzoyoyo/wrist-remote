#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/WristRemoteReleaseToolingTests.XXXXXX")"

cleanup() {
  local allowed_prefix="${TMPDIR:-/tmp}/WristRemoteReleaseToolingTests."
  if [[ -n "$TEMP_ROOT" && "$TEMP_ROOT" == ${allowed_prefix}* && -d "$TEMP_ROOT" ]]; then
    /bin/rm -rf -- "$TEMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

failures=0
check() {
  local description="$1"
  shift
  if "$@"; then
    print -- "ok  $description"
  else
    print -u2 -- "not ok  $description"
    failures=$(( failures + 1 ))
  fi
}

contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]]
}

verify_plan="$(make -C "$REPO_ROOT" -n verify 2>&1 || true)"
check "make verify includes simulator tests" contains "$verify_plan" "scripts/test-simulators.sh"
check "make verify includes the high-severity relay audit" contains "$verify_plan" "npm audit --audit-level=high"

codeql_workflow="$(<"$REPO_ROOT/.github/workflows/codeql.yml")"
codeql_public_gates="$(python3 -c 'import pathlib, re, sys; text = pathlib.Path(sys.argv[1]).read_text(); print(len(re.findall(r"^\s+if:\s*\$\{\{\s*github\.repository_visibility\s*==\s*[\"\x27]public[\"\x27]\s*\}\}\s*$", text, re.MULTILINE)))' "$REPO_ROOT/.github/workflows/codeql.yml")"
check "both CodeQL jobs require public repository visibility" test "$codeql_public_gates" = "2"
check "CodeQL does not depend on a manual enable variable" not_contains "$codeql_workflow" "ENABLE_CODEQL"

security_shebang="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).read_text().splitlines()[0])' "$SCRIPT_DIR/security-check.sh")"
check "security scanner uses Bash available on the Ubuntu CI image" test "$security_shebang" = "#!/usr/bin/env bash"
check "security scanner parses with Bash" /bin/bash -n "$SCRIPT_DIR/security-check.sh"
check "iPhone declares a launch screen instead of legacy scaled presentation" \
  contains "$(<"$REPO_ROOT/apps/WristRemote/project.yml")" 'UILaunchScreen: {}'

bridge_project="$(<"$REPO_ROOT/apps/WristRemoteBridge/project.yml")"
wrist_project="$(<"$REPO_ROOT/apps/WristRemote/project.yml")"
shared_config="$(<"$REPO_ROOT/Config/WristRemote.xcconfig")"
local_config_example="$(<"$REPO_ROOT/Config/Local.xcconfig.example")"
check "iPhone target consumes the dedicated Bundle ID setting" contains "$wrist_project" 'PRODUCT_BUNDLE_IDENTIFIER: $(WRISTREMOTE_IOS_BUNDLE_IDENTIFIER)'
check "Watch target consumes the dedicated Bundle ID setting" contains "$wrist_project" 'PRODUCT_BUNDLE_IDENTIFIER: $(WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER)'
check "Watch companion points to the exact iPhone Bundle ID" contains "$wrist_project" 'WKCompanionAppBundleIdentifier: $(WRISTREMOTE_IOS_BUNDLE_IDENTIFIER)'
check "iPhone Bundle ID has a prefix-derived public default" contains "$shared_config" 'WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = $(WRISTREMOTE_BUNDLE_PREFIX).ios'
check "Watch Bundle ID has an iPhone-derived public default" contains "$shared_config" 'WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = $(WRISTREMOTE_IOS_BUNDLE_IDENTIFIER).watchkitapp'
check "Mac Bridge Bundle ID has a prefix-derived default" contains "$shared_config" 'WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER = $(WRISTREMOTE_BUNDLE_PREFIX).bridge'
check "Mac Bridge project consumes the dedicated Bundle ID setting" contains "$bridge_project" 'PRODUCT_BUNDLE_IDENTIFIER: $(WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER)'
check "ignored local config documents reviewed iPhone identity override" contains "$local_config_example" '// WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = org.example.wristremote.ios'
check "ignored local config documents reviewed Watch identity override" contains "$local_config_example" '// WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = org.example.wristremote.ios.watchkitapp'
check "ignored local config documents the existing-install gate" contains "$local_config_example" '// WRISTREMOTE_EXISTING_INSTALL_REQUIRED = YES'
check "ignored local config documents the original Team anchor" contains "$local_config_example" '// WRISTREMOTE_EXISTING_INSTALL_TEAM_ID = REPLACE_WITH_ORIGINAL_TEAM_ID'
check "ignored local config documents the reviewed Bridge Bundle ID override" contains "$local_config_example" '// WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER = org.example.wristremote.bridge'
codex_notify_source="$(<"$REPO_ROOT/scripts/codex-notify.sh")"
check "Codex hook resolves an explicit Bridge identity before the prefix fallback" \
  contains "$codex_notify_source" 'WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER'
check "Codex hook Keychain service follows the resolved Bridge identity" \
  contains "$codex_notify_source" '-s "${bridge_bundle_identifier}.codex-hook"'
check "Codex hook does not hard-code a prefix-derived Bridge Keychain service" \
  not_contains "$codex_notify_source" '-s "${bundle_prefix}.bridge.codex-hook"'

source "$SCRIPT_DIR/lib/macos-install-safety.zsh"
fixture_target="$TEMP_ROOT/Applications/Wrist Remote Bridge.app"
fixture_target="$(wristremote_canonical_app_path "$fixture_target")"
check "Mac installer ignores unrelated processes" wristremote_assert_install_target_idle "$fixture_target" $'101 /usr/bin/example\n102 /Applications/Other.app/Contents/MacOS/Other'
set +e
wristremote_assert_install_target_idle "$fixture_target" $'201 /tmp/Another.app/Contents/MacOS/WristRemoteBridge' > /dev/null 2>&1
different_bridge_status=$?
wristremote_assert_install_target_idle "$fixture_target" "202 $fixture_target/Contents/MacOS/WristRemoteBridge" > /dev/null 2>&1
exact_bridge_status=$?
set -e
check "Mac installer rejects a Bridge running from another app" test "$different_bridge_status" -ne 0
check "Mac installer requires the exact target app to be quit before replacement" test "$exact_bridge_status" -ne 0
/bin/ln -s "$TEMP_ROOT/nonexistent-target.app" "$TEMP_ROOT/symlink-target.app"
set +e
wristremote_canonical_app_path "$TEMP_ROOT/symlink-target.app" > /dev/null 2>&1
symlink_target_status=$?
set -e
check "Mac installer rejects a symlinked app target" test "$symlink_target_status" -ne 0

fixture_hash_a="$(printf 'A%.0s' {1..40})"
fixture_hash_b="$(printf 'B%.0s' {1..40})"
fixture_hash_c="$(printf 'C%.0s' {1..40})"
single_development_identity=$'  1) '"$fixture_hash_a"$' "Apple Development: Fixture One"\n     1 valid identities found'
multiple_development_identities=$'  1) '"$fixture_hash_a"$' "Apple Development: Fixture One"\n  2) '"$fixture_hash_b"$' "Apple Development: Fixture Two"\n     2 valid identities found'
other_identity=$'  1) '"$fixture_hash_c"$' "Developer ID Application: Fixture"\n     1 valid identities found'

wristremote_choose_codesign_identity '' "$single_development_identity"
check "Mac signer auto-selects one Apple Development identity" test "$WRISTREMOTE_CODESIGN_SELECTION" = "apple-development"
check "Mac signer resolves the auto-selected identity without exposing its name" test "$WRISTREMOTE_SELECTED_CODESIGN_IDENTITY" = "$fixture_hash_a"
wristremote_choose_codesign_identity '' "$other_identity"
check "Mac signer uses ad-hoc only when no Apple Development identity exists" test "$WRISTREMOTE_CODESIGN_SELECTION" = "ad-hoc"
check "Mac signer represents ad-hoc signing explicitly" test "$WRISTREMOTE_SELECTED_CODESIGN_IDENTITY" = "-"
wristremote_choose_codesign_identity 'Apple Development: Fixture One' "$single_development_identity"
check "Mac signer accepts one exact explicit valid identity" test "$WRISTREMOTE_CODESIGN_SELECTION" = "explicit"
wristremote_choose_codesign_identity "${fixture_hash_a:l}" "$single_development_identity"
check "Mac signer accepts an exact explicit certificate hash case-insensitively" test "$WRISTREMOTE_CODESIGN_SELECTION" = "explicit"
wristremote_choose_codesign_identity "${fixture_hash_b:l}" "$multiple_development_identities"
check "Mac signer resolves one explicit identity when automatic selection is ambiguous" test "$WRISTREMOTE_CODESIGN_SELECTION" = "explicit"
successful_selection_output="$(wristremote_choose_codesign_identity '' "$single_development_identity" 2>&1)"
check "successful identity selection emits no certificate details" test -z "$successful_selection_output"
set +e
wristremote_choose_codesign_identity '' "$multiple_development_identities" > /dev/null 2>&1
multiple_identity_status=$?
wristremote_choose_codesign_identity '-' "$single_development_identity" > /dev/null 2>&1
forced_adhoc_status=$?
wristremote_choose_codesign_identity 'missing identity' "$single_development_identity" > /dev/null 2>&1
missing_explicit_status=$?
wristremote_choose_codesign_identity 'Developer ID Application: Fixture' "$other_identity" > /dev/null 2>&1
non_development_explicit_status=$?
wristremote_choose_codesign_identity '' $'unexpected "Apple Development: Fixture" output' > /dev/null 2>&1
unparsed_development_status=$?
set -e
check "Mac signer refuses to guess between multiple Apple Development identities" test "$multiple_identity_status" -ne 0
check "Mac signer does not allow an explicit ad-hoc override" test "$forced_adhoc_status" -ne 0
check "Mac signer rejects an explicit identity that is not locally valid" test "$missing_explicit_status" -ne 0
check "Mac signer rejects non-Apple-Development explicit identities" test "$non_development_explicit_status" -ne 0
check "Mac signer fails closed when an Apple Development identity cannot be parsed" test "$unparsed_development_status" -ne 0

macos_build_script="$(<"$SCRIPT_DIR/build-macos.sh")"
check "Mac installer supports an explicit app target" contains "$macos_build_script" '--target-app'
install_safety_call_count="$(print -r -- "$macos_build_script" | /usr/bin/grep -c 'wristremote_assert_install_target_idle')"
check "Mac installer checks running Bridges before and during replacement" test "$install_safety_call_count" -ge 3
check "Mac build selects a local signing identity through the safety helper" contains "$macos_build_script" 'wristremote_select_codesign_identity'
check "Mac build does not default WRIST_CODESIGN_IDENTITY to ad-hoc" not_contains "$macos_build_script" 'WRIST_CODESIGN_IDENTITY:--'

readonly XCODE_FIXTURE="$TEMP_ROOT/xcode-selection"
/bin/mkdir -p "$XCODE_FIXTURE/Applications"

make_xcode_fixture() {
  local app_name="$1"
  local version="$2"
  local build="$3"
  local prerelease_marker="${4:-stable}"
  local app="$XCODE_FIXTURE/Applications/$app_name"

  /bin/mkdir -p \
    "$app/Contents/Developer/usr/bin" \
    "$app/Contents/MacOS" \
    "$app/Contents/Resources"
  /bin/cat > "$app/Contents/Developer/usr/bin/xcodebuild" <<MOCK
#!/bin/zsh
print -- "Xcode $version"
print -- "Build version $build"
MOCK
  /bin/cat > "$app/Contents/MacOS/Xcode" <<'MOCK'
#!/bin/zsh
exit 0
MOCK
  /bin/chmod 0755 \
    "$app/Contents/Developer/usr/bin/xcodebuild" \
    "$app/Contents/MacOS/Xcode"

  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string com.apple.dt.Xcode \
    "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string Xcode "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string Xcode "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$version" \
    "$app/Contents/Info.plist"
  /usr/bin/plutil -create xml1 "$app/Contents/version.plist"
  /usr/bin/plutil -insert ProductBuildVersion -string "$build" \
    "$app/Contents/version.plist"

  if [[ "$prerelease_marker" == beta-plist ]]; then
    /usr/bin/plutil -create xml1 "$app/Contents/Resources/BetaVersion.plist"
    /usr/bin/plutil -insert seedNumber -string 5 \
      "$app/Contents/Resources/BetaVersion.plist"
  elif [[ "$prerelease_marker" == release-candidate ]]; then
    /usr/bin/plutil -insert CFBundleGetInfoString \
      -string 'Xcode Release Candidate' "$app/Contents/Info.plist"
  fi
}

make_xcode_fixture Xcode.app 26.6 17F113
make_xcode_fixture Xcode-26.7.1.app 26.7.1 17G101
make_xcode_fixture Xcode-27-renamed.app 27.0 27A5237l beta-plist
make_xcode_fixture Xcode-28.app 28.0 28A100 release-candidate
make_xcode_fixture Xcode-99.app 99.0 99A100
/usr/bin/plutil -replace ProductBuildVersion -string 99A999 \
  "$XCODE_FIXTURE/Applications/Xcode-99.app/Contents/version.plist"

stable_active="$XCODE_FIXTURE/Applications/Xcode.app/Contents/Developer"
newest_stable="$XCODE_FIXTURE/Applications/Xcode-26.7.1.app/Contents/Developer"
renamed_beta="$XCODE_FIXTURE/Applications/Xcode-27-renamed.app/Contents/Developer"
release_candidate="$XCODE_FIXTURE/Applications/Xcode-28.app/Contents/Developer"
stable_active="${stable_active:A}"
newest_stable="${newest_stable:A}"
renamed_beta="${renamed_beta:A}"
release_candidate="${release_candidate:A}"

selected_with_stable_active="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=choose-developer-dir \
  WRIST_INSTALLER_TEST_ACTIVE_DIR="$stable_active" \
  WRIST_INSTALLER_TEST_SEARCH_ROOT="$XCODE_FIXTURE/Applications" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "device installer prefers the active full stable Xcode" \
  test "$selected_with_stable_active" = "$stable_active"

selected_with_beta_active="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=choose-developer-dir \
  WRIST_INSTALLER_TEST_ACTIVE_DIR="$renamed_beta" \
  WRIST_INSTALLER_TEST_SEARCH_ROOT="$XCODE_FIXTURE/Applications" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "device installer rejects an active beta and chooses the highest stable Xcode" \
  test "$selected_with_beta_active" = "$newest_stable"

selected_with_rc_active="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=choose-developer-dir \
  WRIST_INSTALLER_TEST_ACTIVE_DIR="$release_candidate" \
  WRIST_INSTALLER_TEST_SEARCH_ROOT="$XCODE_FIXTURE/Applications" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "device installer rejects release-candidate product metadata" \
  test "$selected_with_rc_active" = "$newest_stable"

selected_with_explicit_beta="$(
  WRIST_DEVELOPER_DIR="$renamed_beta" \
  WRIST_INSTALLER_TEST_ENTRYPOINT=choose-developer-dir \
  WRIST_INSTALLER_TEST_SEARCH_ROOT="$XCODE_FIXTURE/Applications" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "explicit WRIST_DEVELOPER_DIR still overrides stable auto-selection" \
  test "$selected_with_explicit_beta" = "$renamed_beta"

installer_source="$(<"$SCRIPT_DIR/install-devices.command")"
doctor_source="$(<"$SCRIPT_DIR/doctor.sh")"
check "doctor fails closed unless the existing-install flag is YES or NO" \
  contains "$doctor_source" 'WRISTREMOTE_EXISTING_INSTALL_REQUIRED must be YES or NO'
check "doctor labels upgrade identity checks as configuration rather than verification" \
  contains "$doctor_source" 'device identities and profiles are not yet verified'
check "doctor requires the real-device dry-run for controlled upgrades" \
  contains "$doctor_source" 'scripts/install-devices.command --dry-run before any device install'
check "doctor rejects an implicit placeholder Bridge identity during controlled upgrade" \
  contains "$doctor_source" 'requires the exact existing Mac Bridge Bundle identifier'

# Exercise the real doctor from an isolated repository, never the developer's
# ignored Local.xcconfig. Tool stubs keep this independent of signing, connected
# devices, the installed Xcode, and the Node version on the test host.
readonly DOCTOR_FIXTURE="$TEMP_ROOT/doctor"
/bin/mkdir -p "$DOCTOR_FIXTURE/repo/scripts" "$DOCTOR_FIXTURE/repo/Config" "$DOCTOR_FIXTURE/bin"
/bin/cp "$SCRIPT_DIR/doctor.sh" "$DOCTOR_FIXTURE/repo/scripts/doctor.sh"
for doctor_tool in xcodebuild xcrun swift xcodegen npm git rg node uname; do
  /bin/cat > "$DOCTOR_FIXTURE/bin/$doctor_tool" <<'MOCK'
#!/bin/zsh -f
case "${0:t}" in
  uname)
    [[ "$*" == '-s' ]] || exit 64
    print -- Darwin
    ;;
  node)
    [[ "${1:-}" == '-e' ]] || exit 64
    exit 0
    ;;
  *)
    # Doctor may verify these commands exist, but must not build, sign, or
    # contact a device while checking the environment.
    exit 70
    ;;
esac
MOCK
  /bin/chmod 0755 "$DOCTOR_FIXTURE/bin/$doctor_tool"
done

reset_doctor_fixture() {
  /bin/cp "$REPO_ROOT/Config/Local.xcconfig.example" "$DOCTOR_FIXTURE/repo/Config/Local.xcconfig"
  /bin/chmod 0600 "$DOCTOR_FIXTURE/repo/Config/Local.xcconfig"
}

run_doctor_fixture() {
  if /usr/bin/env -i PATH="$DOCTOR_FIXTURE/bin:/usr/bin:/bin" \
    /bin/zsh -f "$DOCTOR_FIXTURE/repo/scripts/doctor.sh" "$@" \
    > "$DOCTOR_FIXTURE/output.log" 2>&1; then
    doctor_fixture_status=0
  else
    doctor_fixture_status=$?
  fi
  doctor_fixture_output="$(<"$DOCTOR_FIXTURE/output.log")"
}

reset_doctor_fixture
run_doctor_fixture --unsigned
check "unsigned doctor accepts the unchanged example configuration used by CI" \
  test "$doctor_fixture_status" -eq 0
run_doctor_fixture
check "default doctor still rejects example signing configuration" \
  test "$doctor_fixture_status" -ne 0
check "default doctor reports the placeholder Team as an install configuration error" \
  contains "$doctor_fixture_output" 'WRISTREMOTE_DEVELOPMENT_TEAM must be a 10-character Apple Developer Team ID'

print -r -- 'WRISTREMOTE_EXISTING_INSTALL_REQUIRED = MAYBE' \
  >> "$DOCTOR_FIXTURE/repo/Config/Local.xcconfig"
run_doctor_fixture --unsigned
check "unsigned doctor rejects an invalid existing-install flag" \
  test "$doctor_fixture_status" -ne 0
check "unsigned doctor explains that an existing-install flag must be YES or NO" \
  contains "$doctor_fixture_output" 'WRISTREMOTE_EXISTING_INSTALL_REQUIRED must be YES or NO'

reset_doctor_fixture
/bin/cat >> "$DOCTOR_FIXTURE/repo/Config/Local.xcconfig" <<'CONFIG'
WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = dev.fixture.phone
WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = dev.fixture.unrelated.watchkitapp
CONFIG
run_doctor_fixture --unsigned
check "unsigned doctor rejects Watch identifiers not nested under the configured iPhone" \
  test "$doctor_fixture_status" -ne 0
check "unsigned doctor reports malformed mobile identity nesting" \
  contains "$doctor_fixture_output" 'explicit iPhone and Watch Bundle identifiers must use reverse-domain format and correct nesting'

reset_doctor_fixture
run_doctor_fixture --not-a-doctor-option
check "doctor rejects unknown options" test "$doctor_fixture_status" -ne 0
run_doctor_fixture --unsigned --not-a-doctor-option
check "unsigned doctor does not ignore trailing unknown options" test "$doctor_fixture_status" -ne 0
run_doctor_fixture --unsigned unexpected-positional-argument
check "unsigned doctor rejects unexpected positional arguments" test "$doctor_fixture_status" -ne 0

# An omitted upgrade flag means NO, not malformed configuration. This uses a
# synthetic Team and prefix, so the strict path is tested without local identity.
readonly DOCTOR_TEST_ONLY_TEAM_ID='TEAMFIX123'
/bin/cat > "$DOCTOR_FIXTURE/repo/Config/Local.xcconfig" <<'CONFIG'
WRISTREMOTE_BUNDLE_PREFIX = dev.fixture.wrist
CONFIG
print -r -- "WRISTREMOTE_DEVELOPMENT_TEAM = $DOCTOR_TEST_ONLY_TEAM_ID" \
  >> "$DOCTOR_FIXTURE/repo/Config/Local.xcconfig"
run_doctor_fixture
check "default doctor treats an omitted existing-install flag as NO" \
  test "$doctor_fixture_status" -eq 0

check "device installer does not print candidate UDIDs on ambiguity" \
  not_contains "$installer_source" "item.get('identifier', '无 UDID')"
check "device installer does not echo an invalid requested UDID" \
  not_contains "$installer_source" '平台不符：{requested}'
check "device installer passes the exact iPhone Bundle ID into Xcode" \
  contains "$installer_source" 'WRISTREMOTE_IOS_BUNDLE_IDENTIFIER="$IOS_BUNDLE_ID"'
check "device installer passes the exact Watch Bundle ID into Xcode" \
  contains "$installer_source" 'WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER="$WATCH_BUNDLE_ID"'
final_identity_gate_count="$(print -r -- "$installer_source" | /usr/bin/grep -c 'verify_mobile_install_targets')"
check "device installer re-reads installed identities at the final gate" \
  test "$final_identity_gate_count" -ge 3

readonly BUNDLE_FIXTURE="$TEMP_ROOT/bundle-identities"
/bin/mkdir -p "$BUNDLE_FIXTURE"
/bin/cat > "$BUNDLE_FIXTURE/shared.xcconfig" <<'CONFIG'
WRISTREMOTE_BUNDLE_PREFIX = dev.fixture.wrist
WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = $(WRISTREMOTE_BUNDLE_PREFIX).ios
WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = $(WRISTREMOTE_IOS_BUNDLE_IDENTIFIER).watchkitapp
WRISTREMOTE_EXISTING_INSTALL_REQUIRED = NO
CONFIG
/bin/cat > "$BUNDLE_FIXTURE/local.xcconfig" <<'CONFIG'
WRISTREMOTE_BUNDLE_PREFIX = dev.fixture.custom
CONFIG
derived_identifiers="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=resolve-bundle-identifiers \
  WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
  WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "device installer derives public-default identities from the local prefix" \
  contains "$derived_identifiers" $'IOS=dev.fixture.custom.ios\nWATCH=dev.fixture.custom.ios.watchkitapp\nREQUIRE_EXISTING=NO'

/bin/cat > "$BUNDLE_FIXTURE/local.xcconfig" <<'CONFIG'
WRISTREMOTE_BUNDLE_PREFIX = org.example.wristremote
WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = dev.fixture.legacy
WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = dev.fixture.legacy.watchkitapp
WRISTREMOTE_EXISTING_INSTALL_REQUIRED = YES
WRISTREMOTE_EXISTING_INSTALL_TEAM_ID = TEAMFIX123
CONFIG
upgrade_identifiers="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=resolve-bundle-identifiers \
  WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
  WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "device installer honors reviewed exact upgrade identities" \
  contains "$upgrade_identifiers" $'IOS=dev.fixture.legacy\nWATCH=dev.fixture.legacy.watchkitapp\nREQUIRE_EXISTING=YES'
non_downgraded_requirement="$(
  WRISTREMOTE_EXISTING_INSTALL_REQUIRED=NO \
  WRISTREMOTE_IOS_BUNDLE_IDENTIFIER=dev.fixture.unreviewed \
  WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER=dev.fixture.unreviewed.watchkitapp \
  WRIST_INSTALLER_TEST_ENTRYPOINT=resolve-bundle-identifiers \
  WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
  WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
    "$SCRIPT_DIR/install-devices.command"
)"
check "one-shot environment cannot replace reviewed mobile identities or weaken their gate" \
  contains "$non_downgraded_requirement" $'IOS=dev.fixture.legacy\nWATCH=dev.fixture.legacy.watchkitapp\nREQUIRE_EXISTING=YES'
check "existing-install Team anchor accepts the original Team" \
  env \
    WRIST_INSTALLER_TEST_ENTRYPOINT=validate-existing-team \
    WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
    WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
    WRIST_INSTALLER_TEST_TEAM_ID=TEAMFIX123 \
    "$SCRIPT_DIR/install-devices.command"
set +e
WRIST_INSTALLER_TEST_ENTRYPOINT=validate-existing-team \
WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
WRIST_INSTALLER_TEST_TEAM_ID=OTHERTEAM1 \
  "$SCRIPT_DIR/install-devices.command" > /dev/null 2>&1
wrong_original_team_status=$?
set -e
check "existing-install Team anchor rejects a different current Team" \
  test "$wrong_original_team_status" -ne 0

/bin/cat > "$BUNDLE_FIXTURE/local.xcconfig" <<'CONFIG'
WRISTREMOTE_BUNDLE_PREFIX = org.example.wristremote
WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = org.example.wristremote.ios
WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = org.example.wristremote.ios.watchkitapp
WRISTREMOTE_EXISTING_INSTALL_REQUIRED = YES
WRISTREMOTE_EXISTING_INSTALL_TEAM_ID = TEAMFIX123
CONFIG
set +e
WRIST_INSTALLER_TEST_ENTRYPOINT=resolve-bundle-identifiers \
WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
  "$SCRIPT_DIR/install-devices.command" > /dev/null 2>&1
placeholder_identity_status=$?
set -e
check "device installer rejects placeholder mobile identities" \
  test "$placeholder_identity_status" -ne 0

/bin/cat > "$BUNDLE_FIXTURE/local.xcconfig" <<'CONFIG'
WRISTREMOTE_BUNDLE_PREFIX = ORG.EXAMPLE.WRISTREMOTE
WRISTREMOTE_IOS_BUNDLE_IDENTIFIER = ORG.EXAMPLE.WRISTREMOTE.IOS
WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER = ORG.EXAMPLE.WRISTREMOTE.IOS.watchkitapp
WRISTREMOTE_EXISTING_INSTALL_REQUIRED = YES
WRISTREMOTE_EXISTING_INSTALL_TEAM_ID = TEAMFIX123
CONFIG
set +e
WRIST_INSTALLER_TEST_ENTRYPOINT=resolve-bundle-identifiers \
WRIST_INSTALLER_TEST_SHARED_CONFIG="$BUNDLE_FIXTURE/shared.xcconfig" \
WRIST_INSTALLER_TEST_LOCAL_CONFIG="$BUNDLE_FIXTURE/local.xcconfig" \
  "$SCRIPT_DIR/install-devices.command" > /dev/null 2>&1
uppercase_placeholder_status=$?
set -e
check "device installer rejects case-variant placeholder mobile identities" \
  test "$uppercase_placeholder_status" -ne 0

/bin/cat > "$BUNDLE_FIXTURE/apps-exact.json" <<'JSON'
{"info":{"outcome":"success"},"result":{"apps":[{"bundleIdentifier":"dev.fixture.legacy","displayName":"Wrist Remote"},{"bundleIdentifier":"dev.fixture.legacy.watchkitapp","displayName":"Wrist Remote"}]}}
JSON
exact_classification="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=classify-installed-apps \
  WRIST_INSTALLER_TEST_APPS_JSON="$BUNDLE_FIXTURE/apps-exact.json" \
  WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.legacy \
  WRIST_INSTALLER_TEST_REQUIRE_EXISTING=YES \
    "$SCRIPT_DIR/install-devices.command"
)"
check "existing-install gate accepts the exact identity and ignores its cross-platform companion" \
  test "$exact_classification" = exact

/bin/cat > "$BUNDLE_FIXTURE/apps-mismatch.json" <<'JSON'
{"info":{"outcome":"success"},"result":{"apps":[{"bundleIdentifier":"dev.fixture.other","displayName":"Wrist Remote"}]}}
JSON
set +e
WRIST_INSTALLER_TEST_ENTRYPOINT=classify-installed-apps \
WRIST_INSTALLER_TEST_APPS_JSON="$BUNDLE_FIXTURE/apps-mismatch.json" \
WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.legacy \
WRIST_INSTALLER_TEST_REQUIRE_EXISTING=YES \
  "$SCRIPT_DIR/install-devices.command" > /dev/null 2>&1
mismatched_install_status=$?
set -e
check "existing-install gate rejects a different installed identity" \
  test "$mismatched_install_status" -ne 0

/bin/cat > "$BUNDLE_FIXTURE/apps-empty.json" <<'JSON'
{"info":{"outcome":"success"},"result":{"apps":[]}}
JSON
set +e
WRIST_INSTALLER_TEST_ENTRYPOINT=classify-installed-apps \
WRIST_INSTALLER_TEST_APPS_JSON="$BUNDLE_FIXTURE/apps-empty.json" \
WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.legacy \
WRIST_INSTALLER_TEST_REQUIRE_EXISTING=YES \
  "$SCRIPT_DIR/install-devices.command" > /dev/null 2>&1
missing_upgrade_status=$?
set -e
check "existing-install gate rejects an absent reviewed upgrade target" \
  test "$missing_upgrade_status" -ne 0
fresh_classification="$(
  WRIST_INSTALLER_TEST_ENTRYPOINT=classify-installed-apps \
  WRIST_INSTALLER_TEST_APPS_JSON="$BUNDLE_FIXTURE/apps-empty.json" \
  WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.fresh \
  WRIST_INSTALLER_TEST_REQUIRE_EXISTING=NO \
    "$SCRIPT_DIR/install-devices.command"
)"
check "existing-install gate permits an unambiguous fresh install" \
  test "$fresh_classification" = fresh

readonly PROFILE_FIXTURE="$TEMP_ROOT/profile-identities"
check "installed identity requires exact signed bundle and Team with no ambiguous result" \
  /usr/bin/python3 - "$SCRIPT_DIR/lib/installed-app-identity.py" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("installed_identity", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
app = {"CFBundleIdentifier": "dev.fixture.app", "Entitlements": {
    "application-identifier": "TEAMFIX123.dev.fixture.app",
    "com.apple.developer.team-identifier": "TEAMFIX123"}}
assert module.matches_identity([app], "dev.fixture.app", "TEAMFIX123")
for apps, bundle, team in [
    ([], "dev.fixture.app", "TEAMFIX123"),
    ([app, app], "dev.fixture.app", "TEAMFIX123"),
    ([app], "dev.fixture.other", "TEAMFIX123"),
    ([app], "dev.fixture.app", "OTHERTEAM1"),
    ([{"CFBundleIdentifier": "dev.fixture.app"}], "dev.fixture.app", "TEAMFIX123"),
    ([dict(app, Entitlements={"application-identifier": "TEAMFIX123.dev.fixture.app"})], "dev.fixture.app", "TEAMFIX123"),
]:
    assert not module.matches_identity(apps, bundle, team)
PY
/bin/mkdir -p "$PROFILE_FIXTURE"
/bin/cat > "$PROFILE_FIXTURE/existing.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>TEAMFIX123</string></array>
<key>ExpirationDate</key><date>2035-01-01T00:00:00Z</date>
<key>Entitlements</key><dict><key>application-identifier</key><string>TEAMFIX123.dev.fixture.legacy</string></dict>
</dict></plist>
PLIST
check "profile preflight accepts the same current Team and exact App identity" \
  env \
    WRIST_INSTALLER_TEST_ENTRYPOINT=validate-existing-profile \
    WRIST_INSTALLER_TEST_PROFILE_DIRECTORY="$PROFILE_FIXTURE" \
    WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.legacy \
    WRIST_INSTALLER_TEST_TEAM_ID=TEAMFIX123 \
    "$SCRIPT_DIR/install-devices.command"
set +e
WRIST_INSTALLER_TEST_ENTRYPOINT=validate-existing-profile \
WRIST_INSTALLER_TEST_PROFILE_DIRECTORY="$PROFILE_FIXTURE" \
WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.legacy \
WRIST_INSTALLER_TEST_TEAM_ID=OTHERTEAM1 \
  "$SCRIPT_DIR/install-devices.command" > /dev/null 2>&1
wrong_profile_team_status=$?
set -e
check "profile preflight rejects a different current Team" \
  test "$wrong_profile_team_status" -ne 0

# Renewal must not require the old build to still be valid. Only this
# historical identity fixture expires; the new build's expiry gate stays on.
python3 - "$PROFILE_FIXTURE/existing.plist" <<'PY'
import datetime
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    fixture = plistlib.load(handle)
fixture["ExpirationDate"] = datetime.datetime(2020, 1, 1)
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(fixture, handle)
PY
check "profile renewal accepts expired history with the exact same identity" \
  env \
    WRIST_INSTALLER_TEST_ENTRYPOINT=validate-existing-profile \
    WRIST_INSTALLER_TEST_PROFILE_DIRECTORY="$PROFILE_FIXTURE" \
    WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID=dev.fixture.legacy \
    WRIST_INSTALLER_TEST_TEAM_ID=TEAMFIX123 \
    "$SCRIPT_DIR/install-devices.command"

watch_ui_source="$(<"$REPO_ROOT/apps/WristRemote/Watch/WatchRemoteViews.swift")"
watch_ui_tests="$(<"$REPO_ROOT/apps/WristRemote/WatchUITests/WristRemoteWatchUITests.swift")"
simulator_test_source="$(<"$REPO_ROOT/scripts/test-simulators.sh")"
check "watch page picker has a stable accessibility identifier" contains "$watch_ui_source" '.accessibilityIdentifier("remote-page-picker")'
check "watch UI tests select the first stable page-picker match" contains "$watch_ui_tests" 'app.buttons.matching(identifier: "remote-page-picker").firstMatch'
check "offline watch gate verifies explicit Codex conversation selection" \
  contains "$simulator_test_source" 'testCodexConversationDestinationIsExplicitlySelectable'

readonly SIM_FIXTURE="$TEMP_ROOT/simulator"
/bin/mkdir -p "$SIM_FIXTURE/bin" "$SIM_FIXTURE/tmp"
cat > "$SIM_FIXTURE/devices.json" <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"name":"iPhone Compatible","udid":"IOS-COMPAT","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"name":"iPhone Future","udid":"IOS-FUTURE","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.watchOS-26-2":[{"name":"Apple Watch Compatible","udid":"WATCH-COMPAT","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.watchOS-27-0":[{"name":"Apple Watch Future","udid":"WATCH-FUTURE","isAvailable":true}]}}
JSON
cat > "$SIM_FIXTURE/bin/xcodegen" <<'MOCK'
#!/bin/zsh
exit 0
MOCK
cat > "$SIM_FIXTURE/bin/xcodebuild" <<'MOCK'
#!/bin/zsh
if [[ "$*" == "-version" ]]; then
  print -- "Xcode 26.2"
  print -- "Build version FIXTURE"
  exit 0
fi
print -r -- "xcodebuild $*" >> "$WR_TOOLING_LOG"
MOCK
cat > "$SIM_FIXTURE/bin/xcrun" <<'MOCK'
#!/bin/zsh
case "$*" in
  "simctl list devices available --json")
    /bin/cp "$WR_TOOLING_DEVICES" /dev/stdout
    ;;
  "--sdk iphonesimulator --show-sdk-version"|"--sdk watchsimulator --show-sdk-version")
    print -- "26.2"
    ;;
  *)
    exit 64
    ;;
esac
MOCK
/bin/chmod 0755 "$SIM_FIXTURE/bin/xcodegen" "$SIM_FIXTURE/bin/xcodebuild" "$SIM_FIXTURE/bin/xcrun"
: > "$SIM_FIXTURE/calls.log"
set +e
PATH="$SIM_FIXTURE/bin:$PATH" \
TMPDIR="$SIM_FIXTURE/tmp" \
WR_TOOLING_DEVICES="$SIM_FIXTURE/devices.json" \
WR_TOOLING_LOG="$SIM_FIXTURE/calls.log" \
  "$SCRIPT_DIR/test-simulators.sh" > "$SIM_FIXTURE/output.log" 2>&1
simulator_status=$?
set -e
simulator_calls="$(<"$SIM_FIXTURE/calls.log")"
check "simulator fixture completes" test "$simulator_status" -eq 0
check "iOS runtime does not exceed the active SDK" contains "$simulator_calls" "IOS-COMPAT"
check "watchOS runtime does not exceed the active SDK" contains "$simulator_calls" "WATCH-COMPAT"
check "future iOS runtime is rejected" not_contains "$simulator_calls" "IOS-FUTURE"
check "future watchOS runtime is rejected" not_contains "$simulator_calls" "WATCH-FUTURE"

readonly RELAY_FIXTURE="$TEMP_ROOT/relay"
/bin/mkdir -p "$RELAY_FIXTURE/repo/scripts" "$RELAY_FIXTURE/repo/apps/WristRemoteRelay" "$RELAY_FIXTURE/repo/Config" "$RELAY_FIXTURE/bin"
/bin/cp "$SCRIPT_DIR/deploy-relay.sh" "$RELAY_FIXTURE/repo/scripts/deploy-relay.sh"
print -- "WRISTREMOTE_BUNDLE_PREFIX = org.fixture.wristremote" > "$RELAY_FIXTURE/repo/Config/Local.xcconfig"
cat > "$RELAY_FIXTURE/bin/npm" <<'MOCK'
#!/bin/zsh
exit 0
MOCK
cat > "$RELAY_FIXTURE/bin/npx" <<'MOCK'
#!/bin/zsh
print -- "Deployment completed without a URL"
exit 0
MOCK
cat > "$RELAY_FIXTURE/bin/swift" <<'MOCK'
#!/bin/zsh
print -r -- "unexpected swift invocation" >> "$WR_TOOLING_RELAY_LOG"
exit 70
MOCK
/bin/chmod 0755 "$RELAY_FIXTURE/repo/scripts/deploy-relay.sh" "$RELAY_FIXTURE/bin/npm" "$RELAY_FIXTURE/bin/npx" "$RELAY_FIXTURE/bin/swift"
: > "$RELAY_FIXTURE/swift.log"
set +e
PATH="$RELAY_FIXTURE/bin:$PATH" \
WR_TOOLING_RELAY_LOG="$RELAY_FIXTURE/swift.log" \
  "$RELAY_FIXTURE/repo/scripts/deploy-relay.sh" > "$RELAY_FIXTURE/output.log" 2>&1
relay_status=$?
set -e
relay_output="$(<"$RELAY_FIXTURE/output.log")"
relay_swift_calls="$(<"$RELAY_FIXTURE/swift.log")"
check "relay deployment fails when no HTTPS URL is discoverable" test "$relay_status" -eq 1
check "relay deployment explains how to provide the missing URL" contains "$relay_output" "Could not determine the HTTPS Worker URL"
check "relay provisioning is not invoked without a validated URL" test -z "$relay_swift_calls"

hook_example="$(<"$REPO_ROOT/examples/codex-hooks.json")"
check "Codex hook example uses a symbolic repository-root placeholder" contains "$hook_example" "<REPO_ROOT>/scripts/codex-notify.sh"
check "Codex hook example does not use an absolute-path-shaped placeholder" not_contains "$hook_example" "/absolute/path/to/"

(( failures == 0 )) || {
  print -u2 -- "$failures release-tooling regression check(s) failed."
  exit 1
}
print -- "Release-tooling regression checks passed."
