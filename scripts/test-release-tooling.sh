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

bundle_contract="$(python3 -c 'import pathlib, re, sys; ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", pathlib.Path(sys.argv[1]).read_text()); print("pass" if len(ids) >= 2 and ids[1].startswith(ids[0] + ".") else "fail")' "$REPO_ROOT/apps/WristRemote/project.yml")"
check "watch app bundle ID is namespaced under its iOS companion" test "$bundle_contract" = "pass"

installer_bundle_contract="$(python3 -c 'import pathlib, re, sys; ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", pathlib.Path(sys.argv[1]).read_text()); source = pathlib.Path(sys.argv[2]).read_text(); assignments = dict(re.findall(r"^(IOS|WATCH)_BUNDLE_ID=\"([^\"]+)\"$", source, re.MULTILINE)); normalized = [value.replace("$(WRISTREMOTE_BUNDLE_PREFIX)", "${BUNDLE_PREFIX}") for value in ids[:2]]; print("pass" if len(normalized) == 2 and assignments.get("IOS") == normalized[0] and assignments.get("WATCH") == normalized[1] else "fail")' "$REPO_ROOT/apps/WristRemote/project.yml" "$SCRIPT_DIR/install-devices.command")"
check "real-device installer bundle IDs match generated app bundle IDs" test "$installer_bundle_contract" = "pass"

watch_ui_source="$(<"$REPO_ROOT/apps/WristRemote/Watch/WatchRemoteViews.swift")"
watch_ui_tests="$(<"$REPO_ROOT/apps/WristRemote/WatchUITests/WristRemoteWatchUITests.swift")"
check "watch page picker has a stable accessibility identifier" contains "$watch_ui_source" '.accessibilityIdentifier("remote-page-picker")'
check "watch UI tests select the first stable page-picker match" contains "$watch_ui_tests" 'app.buttons.matching(identifier: "remote-page-picker").firstMatch'

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
