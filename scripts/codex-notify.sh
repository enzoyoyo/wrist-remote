#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly LOCAL_CONFIG="$REPO_ROOT/Config/Local.xcconfig"

(( $# == 0 )) || {
  print -u2 -- "usage: scripts/codex-notify.sh < hook-event.json"
  exit 64
}

readonly TEMP_CONFIG="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/WristRemoteHook.XXXXXX")"

cleanup() {
  [[ -f "$TEMP_CONFIG" ]] && /bin/rm -f -- "$TEMP_CONFIG"
}
trap cleanup EXIT
/bin/chmod 600 "$TEMP_CONFIG"

[[ -f "$LOCAL_CONFIG" ]] || {
  print -u2 -- "Wrist Remote local configuration is missing."
  exit 1
}

bundle_prefix="$(
  /usr/bin/sed -nE \
    's/^[[:space:]]*WRISTREMOTE_BUNDLE_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "$LOCAL_CONFIG" | /usr/bin/tail -n 1
)"
[[ -n "$bundle_prefix" && "$bundle_prefix" != *'.example.'* && "$bundle_prefix" != example.* ]] || {
  print -u2 -- "Configure a unique Wrist Remote Bundle prefix first."
  exit 1
}

token="$(/usr/bin/security find-generic-password \
  -a bearer-token-v1 \
  -s "${bundle_prefix}.bridge.codex-hook" \
  -w 2>/dev/null)" || {
  print -u2 -- "Open WristRemoteBridge once so it can create the local hook token."
  exit 1
}

{
  print -r -- 'url = "http://127.0.0.1:60928/codex-hook"'
  print -r -- 'request = "POST"'
  print -r -- 'header = "Content-Type: application/json"'
  print -r -- "header = \"Authorization: Bearer ${token}\""
  print -r -- 'fail-with-body'
  print -r -- 'silent'
  print -r -- 'show-error'
} > "$TEMP_CONFIG"
unset token

/usr/bin/curl --config "$TEMP_CONFIG" --data-binary @- --output /dev/null
