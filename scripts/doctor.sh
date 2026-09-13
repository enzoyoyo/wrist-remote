#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly LOCAL_CONFIG="$REPO_ROOT/Config/Local.xcconfig"

failed=0
check_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    print -- "ok  $command_name"
  else
    print -u2 -- "missing  $command_name"
    failed=1
  fi
}

check_node() {
  if ! command -v node >/dev/null 2>&1; then
    print -u2 -- "missing  node (Node.js 24 or newer is required)"
    failed=1
  elif node -e '
    const major = Number(process.versions.node.split(".")[0]);
    if (!Number.isInteger(major) || major < 24) process.exit(1);
  ' >/dev/null 2>&1; then
    print -- "ok  node (24+)"
  else
    print -u2 -- "outdated  node (Node.js 24 or newer is required)"
    failed=1
  fi
}

[[ "$(uname -s)" == Darwin ]] || {
  print -u2 -- "missing  macOS"
  failed=1
}
for command_name in xcodebuild xcrun swift xcodegen npm git rg; do
  check_command "$command_name"
done
check_node

if [[ -f "$LOCAL_CONFIG" ]]; then
  permissions="$(/usr/bin/stat -f '%Lp' "$LOCAL_CONFIG")"
  [[ "$permissions" == 600 ]] || {
    print -u2 -- "warning  Config/Local.xcconfig permissions are $permissions; use chmod 600."
  }
  bundle_prefix="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_BUNDLE_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  ios_bundle_identifier="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_IOS_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  watch_bundle_identifier="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  existing_install_required="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_EXISTING_INSTALL_REQUIRED[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  existing_install_team_id="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_EXISTING_INSTALL_TEAM_ID[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  development_team="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  bridge_bundle_identifier="$(
    /usr/bin/sed -nE \
      's/^[[:space:]]*WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
      "$LOCAL_CONFIG" | /usr/bin/tail -n 1
  )"
  bundle_prefix_normalized="${bundle_prefix:l}"
  ios_bundle_identifier_normalized="${ios_bundle_identifier:l}"
  watch_bundle_identifier_normalized="${watch_bundle_identifier:l}"
  bridge_bundle_identifier_normalized="${bridge_bundle_identifier:l}"
  bundle_prefix_is_placeholder=NO
  [[ "$bundle_prefix_normalized" == *'.example.'* \
     || "$bundle_prefix_normalized" == example.* \
     || "$bundle_prefix_normalized" == *'.invalid'* ]] \
    && bundle_prefix_is_placeholder=YES

  mobile_identifiers_present=NO
  [[ -n "$ios_bundle_identifier" || -n "$watch_bundle_identifier" ]] \
    && mobile_identifiers_present=YES
  mobile_identifiers_shape_valid=NO
  if [[ "$ios_bundle_identifier" =~ '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$' \
        && "$watch_bundle_identifier" == "${ios_bundle_identifier}.watchkitapp" ]]; then
    mobile_identifiers_shape_valid=YES
  fi
  mobile_identifiers_non_placeholder=NO
  if [[ "$mobile_identifiers_shape_valid" == YES \
        && "$ios_bundle_identifier_normalized" != *'.example.'* \
        && "$ios_bundle_identifier_normalized" != *'.invalid'* \
        && "$watch_bundle_identifier_normalized" != *'.example.'* \
        && "$watch_bundle_identifier_normalized" != *'.invalid'* ]]; then
    mobile_identifiers_non_placeholder=YES
  fi

  if [[ "${existing_install_required:u}" != YES \
        && "${existing_install_required:u}" != NO ]]; then
    print -u2 -- "invalid  WRISTREMOTE_EXISTING_INSTALL_REQUIRED must be YES or NO"
    failed=1
  elif [[ "${existing_install_required:u}" == YES ]]; then
    if [[ "$mobile_identifiers_shape_valid" == YES \
          && "$existing_install_team_id" =~ '^[A-Z0-9]{10}$' ]]; then
      print -- "ok  controlled-upgrade identity shape configured; device identities and profiles are not yet verified"
      print -- "required  run scripts/install-devices.command --dry-run before any device install"
    else
      print -u2 -- "invalid  controlled upgrade requires exact nested iPhone/Watch identifiers and the original Team anchor"
      failed=1
    fi
  elif [[ "$bundle_prefix_is_placeholder" == YES ]]; then
    print -u2 -- "invalid  replace the example Bundle prefix before a new installation"
    failed=1
  elif [[ "$bundle_prefix" =~ '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$' ]]; then
    print -- "ok  local Bundle prefix configured"
  else
    print -u2 -- "invalid  WRISTREMOTE_BUNDLE_PREFIX must use reverse-domain format"
    failed=1
  fi

  if [[ "$mobile_identifiers_present" == YES \
        && "$mobile_identifiers_shape_valid" != YES ]]; then
    print -u2 -- "invalid  explicit iPhone and Watch Bundle identifiers must use reverse-domain format and correct nesting"
    failed=1
  elif [[ "$mobile_identifiers_present" == YES \
          && "${existing_install_required:u}" != YES \
          && "$mobile_identifiers_non_placeholder" != YES ]]; then
    print -u2 -- "invalid  explicit iPhone and Watch Bundle identifiers must be non-placeholder, reverse-domain, and correctly nested"
    failed=1
  fi
  if [[ ! "$development_team" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 -- "invalid  WRISTREMOTE_DEVELOPMENT_TEAM must be a 10-character Apple Developer Team ID"
    failed=1
  elif [[ "${existing_install_required:u}" == YES \
          && "$development_team" != "$existing_install_team_id" ]]; then
    print -u2 -- "invalid  development Team does not match the controlled-upgrade original Team anchor"
    failed=1
  else
    print -- "ok  local Apple Developer Team configured"
  fi
  if [[ -n "$bridge_bundle_identifier" ]]; then
    if [[ "$bridge_bundle_identifier" =~ '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$' \
          && ( "${existing_install_required:u}" == YES \
               || ( "$bridge_bundle_identifier_normalized" != *'.example.'* \
                    && "$bridge_bundle_identifier_normalized" != *'.invalid'* ) ) ]]; then
      print -- "ok  explicit local Mac Bridge Bundle identifier configured"
    else
      print -u2 -- "invalid  WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER must be non-placeholder reverse-domain format"
      failed=1
    fi
  elif [[ "${existing_install_required:u}" == YES \
          && "$bundle_prefix_is_placeholder" == YES ]]; then
    print -u2 -- "invalid  a controlled upgrade with a placeholder prefix requires the exact existing Mac Bridge Bundle identifier"
    failed=1
  fi
else
  print -u2 -- "missing  Config/Local.xcconfig (run make setup)"
  failed=1
fi

(( failed == 0 )) || exit 1
print -- "Environment checks passed."
