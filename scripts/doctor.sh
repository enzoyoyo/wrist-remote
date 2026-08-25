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
  if [[ "$bundle_prefix" == *'.example.'* || "$bundle_prefix" == example.* ]]; then
    print -u2 -- "warning  replace the example Bundle prefix before installing on devices."
  else
    print -- "ok  local Bundle prefix configured"
  fi
else
  print -u2 -- "missing  Config/Local.xcconfig (run make setup)"
  failed=1
fi

(( failed == 0 )) || exit 1
print -- "Environment checks passed."
