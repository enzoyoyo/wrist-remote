#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly APP_DIR="$REPO_ROOT/apps/WristRemote"
readonly PROJECT="$APP_DIR/WristRemote.xcodeproj"
readonly TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/WristRemoteSimulatorTests.XXXXXX")"
readonly DEVICES_JSON="$TEMP_ROOT/devices.json"

cleanup() {
  local allowed_prefix="${TMPDIR:-/tmp}/WristRemoteSimulatorTests."
  if [[ -n "$TEMP_ROOT" && "$TEMP_ROOT" == ${allowed_prefix}* && -d "$TEMP_ROOT" ]]; then
    /bin/rm -rf -- "$TEMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

for tool in xcodebuild xcrun xcodegen python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    print -u2 -- "Missing required tool: $tool"
    exit 1
  }
done

(
  cd "$APP_DIR"
  xcodegen generate --spec project.yml
)

xcrun simctl list devices available --json > "$DEVICES_JSON"
readonly IOS_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-version)"
readonly WATCH_SIMULATOR_SDK="$(xcrun --sdk watchsimulator --show-sdk-version)"

print -- "Active Xcode:"
xcodebuild -version
print -- "Active Simulator SDKs: iOS $IOS_SIMULATOR_SDK; watchOS $WATCH_SIMULATOR_SDK"

select_simulator() {
  local platform="$1"
  local maximum_sdk_version="$2"
  python3 - "$platform" "$maximum_sdk_version" "$DEVICES_JSON" <<'PY'
import json
import re
import sys

platform, maximum_sdk_text, source = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)

def version_tuple(value):
    parts = [int(part) for part in re.findall(r"\d+", value)]
    if not parts:
        raise SystemExit(f"Could not parse version: {value}")
    return tuple((parts + [0, 0, 0, 0])[:4])

marker = f".SimRuntime.{platform}-"
required_name_prefix = "iPhone" if platform == "iOS" else "Apple Watch"
maximum_sdk = version_tuple(maximum_sdk_text)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    if marker not in runtime:
        continue
    version_text = runtime.split(marker, 1)[1]
    version = version_tuple(version_text)
    if version > maximum_sdk:
        continue
    for device in devices:
        name = str(device.get("name", ""))
        udid = str(device.get("udid", ""))
        if not name.startswith(required_name_prefix) or not udid:
            continue
        if device.get("isAvailable") is False or device.get("availabilityError"):
            continue
        candidates.append((version, name, udid))

if not candidates:
    raise SystemExit(
        f"No available {platform} Simulator device is compatible with active SDK {maximum_sdk_text}."
    )

latest_version = max(item[0] for item in candidates)
latest = sorted(
    (item for item in candidates if item[0] == latest_version),
    key=lambda item: item[1],
)
_, name, udid = latest[0]
print(f"{udid}|{name}")
PY
}

if ! ios_selection="$(select_simulator iOS "$IOS_SIMULATOR_SDK")"; then
  print -u2 -- "Install an iOS Simulator runtime compatible with active SDK $IOS_SIMULATOR_SDK before running simulator tests."
  exit 1
fi
if ! watch_selection="$(select_simulator watchOS "$WATCH_SIMULATOR_SDK")"; then
  print -u2 -- "Install a watchOS Simulator runtime compatible with active SDK $WATCH_SIMULATOR_SDK before running simulator tests."
  exit 1
fi

readonly IOS_UDID="${ios_selection%%|*}"
readonly IOS_NAME="${ios_selection#*|}"
readonly WATCH_UDID="${watch_selection%%|*}"
readonly WATCH_NAME="${watch_selection#*|}"

print -- "iOS unit-test destination: $IOS_NAME"
xcodebuild \
  -project "$PROJECT" \
  -scheme WristRemote \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$IOS_UDID" \
  -derivedDataPath "$TEMP_ROOT/iOSDerivedData" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test

print -- "watchOS UI-smoke destination: $WATCH_NAME"
xcodebuild \
  -project "$PROJECT" \
  -scheme WristRemoteWatchApp \
  -configuration Debug \
  -destination "platform=watchOS Simulator,id=$WATCH_UDID" \
  -derivedDataPath "$TEMP_ROOT/WatchDerivedData" \
  -parallel-testing-enabled NO \
  -only-testing:WristRemoteWatchUITests/WristRemoteWatchUITests/testCodexHomeIsFirstAndAllRemotePagesRemainReachable \
  -only-testing:WristRemoteWatchUITests/WristRemoteWatchUITests/testExplicitPagePickerNeverStartsFromARemoteButton \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test

print -- "Simulator unit and offline UI-smoke tests passed."
