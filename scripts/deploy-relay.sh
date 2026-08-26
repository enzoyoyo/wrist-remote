#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly RELAY_DIR="$REPO_ROOT/apps/WristRemoteRelay"
readonly LOCAL_CONFIG="$REPO_ROOT/Config/Local.xcconfig"

[[ -f "$LOCAL_CONFIG" ]] || {
  print -u2 -- "Run 'make setup' before deploying the relay."
  exit 1
}
command -v curl >/dev/null 2>&1 || { print -u2 -- "curl is required."; exit 1; }

bundle_prefix="$(
  /usr/bin/sed -nE \
    's/^[[:space:]]*WRISTREMOTE_BUNDLE_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "$LOCAL_CONFIG" | /usr/bin/tail -n 1
)"
[[ -n "$bundle_prefix" && "$bundle_prefix" != *'.example.'* && "$bundle_prefix" != example.* ]] || {
  print -u2 -- "Set a unique WRISTREMOTE_BUNDLE_PREFIX in Config/Local.xcconfig first."
  exit 1
}

cd "$RELAY_DIR"
npm ci
npm run check

deployment_output="$(npx wrangler deploy 2>&1)" || {
  print -u2 -- "$deployment_output"
  exit 1
}
print -- "$deployment_output"

discovered_relay_url="$(
  print -r -- "$deployment_output" \
    | rg -o 'https://[A-Za-z0-9.-]+\.workers\.dev(?:/[A-Za-z0-9._~!$&()*+,;=:@%/-]*)?' \
    | /usr/bin/head -n 1 \
    || true
)"
relay_url="${WRISTREMOTE_RELAY_BASE_URL:-$discovered_relay_url}"
[[ "$relay_url" == https://* ]] || {
  print -u2 -- "Could not determine the HTTPS Worker URL. Re-run with WRISTREMOTE_RELAY_BASE_URL=https://your-worker.example."
  exit 1
}

swift "$SCRIPT_DIR/provision-relay.swift" \
  --base-url "$relay_url" \
  --bundle-prefix "$bundle_prefix" \
  --relay-dir "$RELAY_DIR" \
  --xcconfig "$LOCAL_CONFIG"

health_url="${relay_url%/}/healthz"
for attempt in {1..30}; do
  health_json="$(curl --fail --silent --show-error "$health_url" 2>/dev/null || true)"
  if print -r -- "$health_json" | rg -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    print -- "Private relay is configured and healthy: $health_url"
    print -- "Rebuild the Mac, iPhone, and Watch apps so they use the new URL."
    exit 0
  fi
  /bin/sleep 1
done

print -u2 -- "The Worker deployed, but its configured health check did not become ready."
exit 1
