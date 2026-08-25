#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly APP_DIR="$REPO_ROOT/apps/WristRemote"
readonly PROJECT="$APP_DIR/WristRemote.xcodeproj"
readonly LOCAL_CONFIG="$REPO_ROOT/Config/Local.xcconfig"

BUNDLE_PREFIX=''
IOS_BUNDLE_ID=''
WATCH_BUNDLE_ID=''

DRY_RUN=0
TEMP_ROOT=''

usage() {
  /bin/cat <<'USAGE'
Wrist Remote 真机签名与安装 / Device signing and installation

用法：
  scripts/install-devices.command
  scripts/install-devices.command --dry-run
  scripts/install-devices.command --help

默认行为：
  1. 自动选择本机最高版本的完整 Xcode，不修改全局 xcode-select。
  2. 自动选择唯一可用的真机 iPhone 和 Apple Watch。
  3. 从钥匙串唯一的 Apple Development 身份临时取得 Team ID。
  4. 先按 Apple Watch UDID 构建，再构建 iPhone 伴侣 App。
  5. 校验三个 App 包的签名、描述文件、有效期和目标设备白名单。
  6. 依次安装 iPhone、Apple Watch，查询安装结果并启动。
  7. 启动 iPhone 与 Apple Watch App。

只在自动选择出现歧义时，才对当前一次运行设置以下环境变量：
  WRIST_DEVELOPER_DIR  Xcode 的 Contents/Developer 绝对路径
  WRIST_TEAM_ID        10 位 Apple Developer Team ID
  WRIST_IPHONE_UDID    目标 iPhone UDID
  WRIST_WATCH_UDID     目标 Apple Watch UDID

--dry-run 只执行只读前置检查，不构建、不注册设备、不签名、不安装、不启动。
脚本不会把 Team ID、UDID、账号或凭据写入仓库。

The script auto-selects one connected iPhone, one connected Apple Watch,
and one Apple Development identity. Set the temporary environment variables
above only when automatic selection is ambiguous. Nothing is uploaded.
USAGE
}

die() {
  print -u2 -- "失败：$*"
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    local allowed_prefix="${TMPDIR:-/tmp}/WristRemoteInstall."
    if [[ "$TEMP_ROOT" == ${allowed_prefix}* ]]; then
      /bin/rm -rf -- "$TEMP_ROOT"
    else
      print -u2 -- "警告：临时目录不符合安全前缀，未自动删除：$TEMP_ROOT"
    fi
  fi
}
trap cleanup EXIT

for argument in "$@"; do
  case "$argument" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "未知参数：$argument"
      ;;
  esac
done

choose_developer_dir() {
  if [[ -n "${WRIST_DEVELOPER_DIR:-}" ]]; then
    [[ -x "$WRIST_DEVELOPER_DIR/usr/bin/xcodebuild" ]] || {
      print -u2 -- "WRIST_DEVELOPER_DIR 不是有效的 Xcode Developer 目录：$WRIST_DEVELOPER_DIR"
      return 1
    }
    print -r -- "$WRIST_DEVELOPER_DIR"
    return 0
  fi

  local -a candidates
  local active candidate version major minor
  local best='' best_major=-1 best_minor=-1

  active="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  [[ -n "$active" ]] && candidates+=("$active")
  candidates+=(/Applications/Xcode*.app/Contents/Developer(N))

  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate/usr/bin/xcodebuild" ]] || continue
    version="$(
      DEVELOPER_DIR="$candidate" "$candidate/usr/bin/xcodebuild" -version 2>/dev/null \
        | /usr/bin/awk 'NR == 1 {print $2}'
    )"
    [[ "$version" =~ '^([0-9]+)(\.([0-9]+))?' ]] || continue
    major="${match[1]}"
    minor="${match[3]:-0}"
    if (( major > best_major || (major == best_major && minor >= best_minor) )); then
      best="$candidate"
      best_major="$major"
      best_minor="$minor"
    fi
  done

  [[ -n "$best" ]] || {
    print -u2 -- '没有找到完整 Xcode。请先安装 Xcode，或临时设置 WRIST_DEVELOPER_DIR。'
    return 1
  }
  print -r -- "$best"
}

select_device() {
  local platform="$1"
  local label="$2"
  local requested="${3:-}"

  /usr/bin/python3 - "$DEVICES_JSON" "$platform" "$label" "$requested" <<'PY'
import json
import sys

path, platform, label, requested = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        devices = json.load(handle)
except Exception as error:
    print(f"无法解析 Xcode 设备列表：{error}", file=sys.stderr)
    raise SystemExit(2)

matches = [
    item
    for item in devices
    if not item.get("simulator", False)
    and item.get("platform") == platform
    and not item.get("ignored", False)
]

if requested:
    matches = [
        item
        for item in matches
        if requested in (item.get("identifier"), item.get("hardwareUDID"))
    ]
    if not matches:
        print(f"{label} 指定的 UDID 不存在或平台不符：{requested}", file=sys.stderr)
        raise SystemExit(3)
else:
    matches = [item for item in matches if item.get("available") is True]

if len(matches) != 1:
    if not matches:
        print(
            f"未发现唯一可用的真机 {label}。请开启设备、启用开发者模式并保持连接。",
            file=sys.stderr,
        )
    else:
        summary = ", ".join(
            f"{item.get('name', '未命名')} ({item.get('identifier', '无 UDID')})"
            for item in matches
        )
        env_name = (
            "WRIST_IPHONE_UDID"
            if platform.endswith("iphoneos")
            else "WRIST_WATCH_UDID"
        )
        print(f"发现多个可用 {label}：{summary}", file=sys.stderr)
        print(
            f"为避免装错设备，请只对本次运行设置 {env_name}=目标UDID。",
            file=sys.stderr,
        )
    raise SystemExit(4)

item = matches[0]
if item.get("available") is not True:
    print(f"{label} 当前不可用：{item.get('name', '未命名')}", file=sys.stderr)
    raise SystemExit(5)

print(
    f"已选择 {label}：{item.get('name', '未命名')}，系统 "
    f"{item.get('operatingSystemVersion', '未知')}",
    file=sys.stderr,
)
print(item["identifier"])
PY
}

device_os_major() {
  /usr/bin/python3 - "$DEVICES_JSON" "$1" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    devices = json.load(handle)

for item in devices:
    if item.get("identifier") == sys.argv[2]:
        match = re.match(r"(\d+)", item.get("operatingSystemVersion", ""))
        if match:
            print(match.group(1))
            raise SystemExit(0)

print("无法读取设备系统主版本。", file=sys.stderr)
raise SystemExit(1)
PY
}

device_hardware_udid() {
  /usr/bin/python3 - "$DEVICES_JSON" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    devices = json.load(handle)

for item in devices:
    if item.get("identifier") == sys.argv[2]:
        hardware_udid = item.get("hardwareUDID")
        if hardware_udid:
            print(hardware_udid)
            raise SystemExit(0)

print("无法读取设备用于开发描述文件的硬件 UDID。", file=sys.stderr)
raise SystemExit(1)
PY
}

preflight_device() {
  local udid="$1"
  local label="$2"
  local slug="$3"
  local details="$TEMP_ROOT/details-${slug}.json"

  if ! /usr/bin/xcrun devicectl device info details \
      --device "$udid" \
      --timeout 30 \
      --quiet \
      --json-output "$details"; then
    die "$label 无法建立开发连接；请保持蓝牙/Wi-Fi 或 USB 连接。"
  fi

  if ! /usr/bin/python3 - "$details" "$label" <<'PY'
import json
import sys

path, label = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)

if document.get("info", {}).get("outcome") != "success":
    print(f"{label} 的 CoreDevice 检查未成功。", file=sys.stderr)
    raise SystemExit(2)

result = document.get("result", {})
legacy_device = result.get("deviceProperties", {})
legacy_connection = result.get("connectionProperties", {})
properties = result.get("properties", {})
state = properties.get("state", {})
connection = properties.get("connection", {})

pairing = legacy_connection.get("pairingState") or connection.get("pairingState")
if pairing and pairing != "paired":
    print(f"{label} 尚未与这台 Mac 完成开发配对。", file=sys.stderr)
    raise SystemExit(3)

legacy_mode = legacy_device.get("developerModeStatus")
new_mode = state.get("developerModeStatus", {})
developer_enabled = legacy_mode == "enabled" or (
    isinstance(new_mode, dict) and "enabled" in new_mode
)
if not developer_enabled:
    print(f"{label} 的开发者模式未启用。", file=sys.stderr)
    raise SystemExit(4)

ddi_available = legacy_device.get("ddiServicesAvailable")
if ddi_available is False:
    print(
        f"{label} 尚未准备好开发者磁盘服务；等待 Xcode 准备完成后重试。",
        file=sys.stderr,
    )
    raise SystemExit(5)
PY
  then
    die "$label 的开发前置条件不满足。"
  fi

  check_lock_state "$udid" "$label" "$slug"
}

check_lock_state() {
  local udid="$1"
  local label="$2"
  local slug="$3"
  local lock_json="$TEMP_ROOT/lock-${slug}.json"
  local lock_status

  if ! /usr/bin/xcrun devicectl device info lockState \
      --device "$udid" \
      --timeout 30 \
      --quiet \
      --json-output "$lock_json"; then
    die "无法读取 $label 的锁定状态。"
  fi

  if ! lock_status="$(/usr/bin/python3 - "$lock_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)

if document.get("info", {}).get("outcome") != "success":
    raise SystemExit(2)

result = document.get("result", {})
if result.get("passcodeRequired") is True:
    print("locked")
elif result.get("unlockedSinceBoot") is False:
    print("not-unlocked-since-boot")
else:
    print("ready")
PY
  )"; then
    die "无法解析 $label 的锁定状态。"
  fi

  if [[ "$lock_status" != ready ]]; then
    if (( DRY_RUN )); then
      print -u2 -- "只读检查提示：$label 当前锁定；实际重装会要求先在设备上解锁。"
    else
      die "$label 当前锁定。请在设备上解锁并保持屏幕唤醒，然后重新运行。"
    fi
  fi
}

select_team_id() {
  if [[ -n "${WRIST_TEAM_ID:-}" ]]; then
    [[ "$WRIST_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || {
      print -u2 -- 'WRIST_TEAM_ID 格式无效，应为 10 位大写字母或数字。'
      return 1
    }
    print -r -- "$WRIST_TEAM_ID"
    return 0
  fi

  local identities="$TEMP_ROOT/code-signing-identities.txt"
  local identity_name certificate_subject
  /usr/bin/security find-identity -v -p codesigning > "$identities" 2>/dev/null || true

  if ! identity_name="$(/usr/bin/python3 - "$identities" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    text = handle.read()

identities = sorted(
    set(
        re.findall(
            r'"((?:Apple Development|iPhone Developer): [^"]+)"',
            text,
        )
    )
)

if len(identities) == 1:
    print(identities[0])
    raise SystemExit(0)

if not identities:
    print(
        "钥匙串中没有有效的 Apple Development 签名身份；"
        "请先在 Xcode 登录账号并创建开发证书。",
        file=sys.stderr,
    )
else:
    print(
        "发现多个 Apple Development Team；为避免使用错误身份，"
        "请只对本次运行设置 WRIST_TEAM_ID。",
        file=sys.stderr,
    )
raise SystemExit(2)
PY
  )"; then
    return 1
  fi

  # The 10-character value displayed in the certificate common name is the
  # creator identifier and can differ from the Developer Team ID. Read the
  # authoritative Team ID from the certificate subject's OU field.
  if ! certificate_subject="$(
    /usr/bin/security find-certificate -c "$identity_name" -p \
      | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null
  )"; then
    print -u2 -- "无法读取 Apple Development 证书：$identity_name"
    return 1
  fi

  /usr/bin/python3 - "$certificate_subject" <<'PY'
import re
import sys

subject = sys.argv[1].removeprefix("subject=").strip()
teams = sorted(set(re.findall(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", subject)))
if len(teams) != 1:
    print("Apple Development 证书中没有唯一的 10 位 Team ID。", file=sys.stderr)
    raise SystemExit(2)
print(teams[0])
PY
}

build_target() {
  local scheme="$1"
  local destination="$2"
  local label="$3"

  print -- "正在构建并自动签名 $label…"
  if ! /usr/bin/xcodebuild \
      -project "$PROJECT" \
      -scheme "$scheme" \
      -configuration Debug \
      -destination "$destination" \
      -destination-timeout 120 \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      WRISTREMOTE_BUNDLE_PREFIX="$BUNDLE_PREFIX" \
      DEVELOPMENT_TEAM="$TEAM_ID" \
      CODE_SIGN_STYLE=Automatic \
      -quiet \
      build; then
    die "$label 构建或自动签名失败；请查看上方 Xcode 错误。"
  fi
}

verify_profile() {
  local app="$1"
  local bundle_id="$2"
  local expected_udid="$3"
  local label="$4"
  local slug="$5"
  local profile_plist="$TEMP_ROOT/profile-${slug}.plist"
  local actual_bundle

  [[ -d "$app" ]] || die "$label 构建产物不存在：$app"
  /usr/bin/codesign --verify --deep --strict "$app" \
    || die "$label 的代码签名结构校验失败。"

  actual_bundle="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist"
  )"
  [[ "$actual_bundle" == "$bundle_id" ]] \
    || die "$label Bundle ID 不符合预期：$actual_bundle"

  [[ -f "$app/embedded.mobileprovision" ]] || die "$label 缺少开发描述文件。"
  /usr/bin/security cms -D -i "$app/embedded.mobileprovision" \
      > "$profile_plist" 2>/dev/null \
    || die "$label 描述文件无法解析。"

  /usr/bin/python3 - \
      "$profile_plist" "$TEAM_ID" "$bundle_id" "$expected_udid" "$label" <<'PY'
import datetime
import plistlib
import sys

path, team, bundle_id, udid, label = sys.argv[1:]
with open(path, "rb") as handle:
    profile = plistlib.load(handle)

if team not in profile.get("TeamIdentifier", []):
    print(f"{label} 描述文件的 Team 与本次签名身份不一致。", file=sys.stderr)
    raise SystemExit(2)

if udid not in profile.get("ProvisionedDevices", []):
    print(
        f"{label} 描述文件不包含目标设备；已阻止安装到错误设备。",
        file=sys.stderr,
    )
    raise SystemExit(3)

application_id = profile.get("Entitlements", {}).get("application-identifier", "")
if application_id not in (f"{team}.{bundle_id}", f"{team}.*"):
    print(f"{label} 描述文件的 application-identifier 不匹配。", file=sys.stderr)
    raise SystemExit(4)

expires = profile.get("ExpirationDate")
if not isinstance(expires, datetime.datetime):
    print(f"{label} 描述文件没有有效到期时间。", file=sys.stderr)
    raise SystemExit(5)

if expires.tzinfo is None:
    expires = expires.replace(tzinfo=datetime.timezone.utc)
if expires <= datetime.datetime.now(datetime.timezone.utc):
    print(f"{label} 描述文件已经过期。", file=sys.stderr)
    raise SystemExit(6)

print(
    f"{label} 签名有效至 {expires.astimezone(datetime.timezone.utc).isoformat(timespec='minutes')}",
    file=sys.stderr,
)
PY
}

assert_devicectl_success() {
  local json_path="$1"
  local label="$2"

  /usr/bin/python3 - "$json_path" "$label" <<'PY'
import json
import sys

path, label = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
if document.get("info", {}).get("outcome") != "success":
    print(f"{label} 的 devicectl 结果不是 success。", file=sys.stderr)
    raise SystemExit(2)
PY
}

install_and_verify() {
  local udid="$1"
  local app="$2"
  local bundle_id="$3"
  local label="$4"
  local slug="$5"
  local install_json="$TEMP_ROOT/install-${slug}.json"
  local apps_json="$TEMP_ROOT/apps-${slug}.json"

  print -- "正在安装 $label…"
  if ! /usr/bin/xcrun devicectl device install app \
      --device "$udid" \
      "$app" \
      --timeout 120 \
      --quiet \
      --json-output "$install_json"; then
    die "$label 安装失败。请解锁对应设备、保持屏幕唤醒和连接，然后重新运行。"
  fi
  assert_devicectl_success "$install_json" "$label 安装" \
    || die "$label 安装结果校验失败。"

  if ! /usr/bin/xcrun devicectl device info apps \
      --device "$udid" \
      --bundle-id "$bundle_id" \
      --timeout 30 \
      --quiet \
      --json-output "$apps_json"; then
    die "$label 安装后无法查询 App 列表。"
  fi

  /usr/bin/python3 - "$apps_json" "$bundle_id" "$label" <<'PY'
import json
import sys

path, bundle_id, label = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)

if document.get("info", {}).get("outcome") != "success":
    print(f"{label} 安装后查询未成功。", file=sys.stderr)
    raise SystemExit(2)

apps = document.get("result", {}).get("apps", [])
if not any(app.get("bundleIdentifier") == bundle_id for app in apps):
    print(f"{label} 未出现在设备已安装 App 列表中。", file=sys.stderr)
    raise SystemExit(3)
PY
}

launch_app() {
  local udid="$1"
  local bundle_id="$2"
  local label="$3"
  local slug="$4"
  local launch_json="$TEMP_ROOT/launch-${slug}.json"

  print -- "正在启动 $label…"
  if ! /usr/bin/xcrun devicectl device process launch \
      --device "$udid" \
      --terminate-existing \
      "$bundle_id" \
      --timeout 60 \
      --quiet \
      --json-output "$launch_json"; then
    die "$label 已安装，但自动启动失败。请解锁对应设备后重新运行。"
  fi
  assert_devicectl_success "$launch_json" "$label 启动" \
    || die "$label 启动结果校验失败。"
}

command -v xcodegen >/dev/null 2>&1 \
  || die '找不到 XcodeGen。请先运行 make setup。'
[[ -f "$LOCAL_CONFIG" ]] \
  || die '缺少 Config/Local.xcconfig。请先运行 make setup 并填写唯一 Bundle 前缀。'

BUNDLE_PREFIX="${WRISTREMOTE_BUNDLE_PREFIX:-$(
  /usr/bin/sed -nE \
    's/^[[:space:]]*WRISTREMOTE_BUNDLE_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "$LOCAL_CONFIG" | /usr/bin/tail -n 1
)}"
[[ "$BUNDLE_PREFIX" =~ '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$' ]] \
  || die 'WRISTREMOTE_BUNDLE_PREFIX 必须是反向域名格式，例如 org.example.wristremote。'
[[ "$BUNDLE_PREFIX" != *'.example.'* && "$BUNDLE_PREFIX" != example.* ]] \
  || die '真机安装前请在 Config/Local.xcconfig 设置你自己的唯一 Bundle 前缀。'
IOS_BUNDLE_ID="${BUNDLE_PREFIX}.ios"
WATCH_BUNDLE_ID="${BUNDLE_PREFIX}.watchkitapp"
readonly BUNDLE_PREFIX IOS_BUNDLE_ID WATCH_BUNDLE_ID

cd "$APP_DIR"
xcodegen generate --spec project.yml >/dev/null
[[ -d "$PROJECT" ]] || die "无法生成 Xcode 工程：$PROJECT"

if ! DEVELOPER_DIR="$(choose_developer_dir)"; then
  die '无法选择可用 Xcode。'
fi
export DEVELOPER_DIR

/usr/bin/xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
  || die '所选 Xcode 缺少 iPhoneOS SDK。'
/usr/bin/xcrun --sdk watchos --show-sdk-path >/dev/null 2>&1 \
  || die '所选 Xcode 缺少 WatchOS SDK。'

print -- "使用 $(/usr/bin/xcodebuild -version | /usr/bin/awk 'NR == 1 {print}')"

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/WristRemoteInstall.XXXXXX")"
readonly TEMP_ROOT
readonly DEVICES_JSON="$TEMP_ROOT/xcdevice.json"
readonly CORE_DEVICES_JSON="$TEMP_ROOT/core-devices.json"

if ! /usr/bin/xcrun devicectl list devices \
    --timeout 30 \
    --quiet \
    --json-output "$CORE_DEVICES_JSON"; then
  die 'Xcode CoreDevice 无法读取设备列表。'
fi
if ! /usr/bin/python3 - "$CORE_DEVICES_JSON" "$DEVICES_JSON" <<'PY'
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
if document.get("info", {}).get("outcome") != "success":
    raise SystemExit(2)

platforms = {
    "iOS": "com.apple.platform.iphoneos",
    "watchOS": "com.apple.platform.watchos",
}
normalized = []
for device in document.get("result", {}).get("devices", []):
    properties = device.get("properties", {})
    hardware = properties.get("hardware", {})
    software = properties.get("software", {})
    connection = properties.get("connection", {})
    state = properties.get("state", {})
    legacy_device = device.get("deviceProperties", {})
    platform = platforms.get(hardware.get("platform"))
    if not platform:
        continue
    version = software.get("osVersionNumber", {})
    if isinstance(version, dict):
        version = version.get("stringValue")
    version = version or legacy_device.get("osVersionNumber") or "未知"
    normalized.append({
        "name": state.get("name") or legacy_device.get("name") or "未命名",
        "identifier": device.get("identifier"),
        "hardwareUDID": (
            hardware.get("udid")
            or device.get("hardwareProperties", {}).get("udid")
            or legacy_device.get("udid")
        ),
        "platform": platform,
        "operatingSystemVersion": version,
        "available": connection.get("state") == "connected",
        "simulator": hardware.get("reality") != "physical",
        "ignored": False,
    })

with open(destination, "w", encoding="utf-8") as handle:
    json.dump(normalized, handle)
PY
then
  die '无法解析 Xcode CoreDevice 设备列表。'
fi

if ! IPHONE_UDID="$(
  select_device \
    com.apple.platform.iphoneos \
    iPhone \
    "${WRIST_IPHONE_UDID:-}"
)"; then
  die '无法唯一确定目标 iPhone。'
fi

if ! WATCH_UDID="$(
  select_device \
    com.apple.platform.watchos \
    'Apple Watch' \
    "${WRIST_WATCH_UDID:-}"
)"; then
  die '无法唯一确定目标 Apple Watch。'
fi
readonly IPHONE_UDID WATCH_UDID

if ! IPHONE_HARDWARE_UDID="$(device_hardware_udid "$IPHONE_UDID")"; then
  die '无法确定 iPhone 的硬件 UDID。'
fi
if ! WATCH_HARDWARE_UDID="$(device_hardware_udid "$WATCH_UDID")"; then
  die '无法确定 Apple Watch 的硬件 UDID。'
fi
readonly IPHONE_HARDWARE_UDID WATCH_HARDWARE_UDID

preflight_device "$IPHONE_UDID" iPhone iphone
preflight_device "$WATCH_UDID" 'Apple Watch' watch

if ! IPHONE_OS_MAJOR="$(device_os_major "$IPHONE_UDID")"; then
  die '无法确定 iPhone 系统版本。'
fi
if ! WATCH_OS_MAJOR="$(device_os_major "$WATCH_UDID")"; then
  die '无法确定 Apple Watch 系统版本。'
fi

IPHONE_SDK_VERSION="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-version)"
WATCH_SDK_VERSION="$(/usr/bin/xcrun --sdk watchos --show-sdk-version)"
IPHONE_SDK_MAJOR="${IPHONE_SDK_VERSION%%.*}"
WATCH_SDK_MAJOR="${WATCH_SDK_VERSION%%.*}"

(( IPHONE_SDK_MAJOR >= IPHONE_OS_MAJOR )) \
  || die "iPhoneOS SDK $IPHONE_SDK_VERSION 早于 iPhone 系统主版本。"
(( WATCH_SDK_MAJOR >= WATCH_OS_MAJOR )) \
  || die "WatchOS SDK $WATCH_SDK_VERSION 早于 Apple Watch 系统主版本。"

if ! TEAM_ID="$(select_team_id)"; then
  die '无法唯一确定 Apple Development Team。'
fi
readonly TEAM_ID
print -- '已从钥匙串选择 Apple Development 身份（不会写入工程）。'

if (( DRY_RUN )); then
  print -- '只读检查通过：未构建、未注册设备、未签名、未安装、未启动。'
  print -- '实际执行顺序：Watch 构建 → iPhone 构建 → 三包校验 → iPhone 安装 → Watch 安装 → 两端启动。'
  exit 0
fi

readonly DERIVED_DATA="$TEMP_ROOT/DerivedData"
readonly WATCH_APP="$DERIVED_DATA/Build/Products/Debug-watchos/WristRemoteWatchApp.app"
readonly IPHONE_APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/WristRemote.app"
readonly EMBEDDED_WATCH_APP="$IPHONE_APP/Watch/WristRemoteWatchApp.app"

# 首次签名必须先按 Watch 自身 UDID 建立包含手表的开发描述文件。
build_target \
  WristRemoteWatchApp \
  "platform=watchOS,id=$WATCH_UDID" \
  'Apple Watch App'

# 再构建伴侣，确保嵌入的 Watch App 复用已经包含手表的描述文件。
build_target \
  WristRemote \
  "platform=iOS,id=$IPHONE_UDID" \
  'iPhone 伴侣 App'

verify_profile \
  "$WATCH_APP" \
  "$WATCH_BUNDLE_ID" \
  "$WATCH_HARDWARE_UDID" \
  '独立 Apple Watch App' \
  watch-standalone
verify_profile \
  "$IPHONE_APP" \
  "$IOS_BUNDLE_ID" \
  "$IPHONE_HARDWARE_UDID" \
  'iPhone 伴侣 App' \
  iphone
verify_profile \
  "$EMBEDDED_WATCH_APP" \
  "$WATCH_BUNDLE_ID" \
  "$WATCH_HARDWARE_UDID" \
  'iPhone 包内嵌 Apple Watch App' \
  watch-embedded

install_and_verify \
  "$IPHONE_UDID" \
  "$IPHONE_APP" \
  "$IOS_BUNDLE_ID" \
  'iPhone 伴侣 App' \
  iphone
install_and_verify \
  "$WATCH_UDID" \
  "$WATCH_APP" \
  "$WATCH_BUNDLE_ID" \
  'Apple Watch App' \
  watch

launch_app "$IPHONE_UDID" "$IOS_BUNDLE_ID" 'iPhone 伴侣 App' iphone
launch_app "$WATCH_UDID" "$WATCH_BUNDLE_ID" 'Apple Watch App' watch

print -- '完成：iPhone 与 Apple Watch 已重新签名、安装并启动。'
print -- 'Wrist Remote 使用独立 Bundle ID、协议与存储，不读取或修改其他遥控器配置。'
