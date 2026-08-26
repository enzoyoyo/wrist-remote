#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/WristRemoteTests.XXXXXX")"
trap '/bin/rm -rf -- "$TEMP_ROOT"' EXIT

"$SCRIPT_DIR/doctor.sh"
"$SCRIPT_DIR/test-release-tooling.sh"

(
  cd "$REPO_ROOT/apps/WristRemote"
  xcodegen generate --spec project.yml
  swift test
)

(
  cd "$REPO_ROOT/apps/WristRemoteBridge"
  xcodegen generate --spec project.yml
  xcodebuild \
    -project WristRemoteBridge.xcodeproj \
    -scheme WristRemoteBridge \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$TEMP_ROOT/BridgeDerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    test
)

(
  cd "$REPO_ROOT/apps/WristRemoteRelay"
  npm ci
  npm run check
)

print -- "All automated tests passed."
