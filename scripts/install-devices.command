#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly APP_DIR="$REPO_ROOT/apps/WristRemote"
readonly PROJECT="$APP_DIR/WristRemote.xcodeproj"
readonly SHARED_CONFIG="$REPO_ROOT/Config/WristRemote.xcconfig"
readonly LOCAL_CONFIG="$REPO_ROOT/Config/Local.xcconfig"

BUNDLE_PREFIX=''
IOS_BUNDLE_ID=''
WATCH_BUNDLE_ID=''
EXISTING_INSTALL_REQUIRED='NO'
EXISTING_INSTALL_TEAM_ID=''

DRY_RUN=0
ALLOW_WATCH_FIRST_INSTALL=0
WATCH_INSTALL_CLASSIFICATION=''
TEMP_ROOT=''

usage() {
  /bin/cat <<'USAGE'
Wrist Remote 真机签名与安装 / Device signing and installation

用法：
  scripts/install-devices.command
  scripts/install-devices.command --dry-run
  scripts/install-devices.command --allow-watch-first-install
  scripts/install-devices.command --help

默认行为：
  1. 优先使用 xcode-select 指向的完整稳定版 Xcode；否则选择最高稳定版。
  2. 自动选择唯一可用的真机 iPhone 和 Apple Watch。
  3. 从钥匙串唯一的 Apple Development 身份临时取得 Team ID。
  4. 先按 Apple Watch UDID 构建，再构建 iPhone 伴侣 App。
  5. 校验历史升级身份、当前 Team、现装 App 身份及三个 App 包的描述文件。
  6. 先利用新鲜配对隧道安装 Apple Watch，再原位升级 iPhone 并查询结果。
  7. 启动 iPhone 与 Apple Watch App。

只在自动选择出现歧义时，才对当前一次运行设置以下环境变量：
  WRIST_DEVELOPER_DIR  Xcode 的 Contents/Developer 绝对路径
  WRIST_TEAM_ID        10 位 Apple Developer Team ID
  WRIST_IPHONE_UDID    目标 iPhone UDID
  WRIST_WATCH_UDID     目标 Apple Watch UDID

--dry-run 只执行只读前置检查，不构建、不注册设备、不签名、不安装、不启动。
--allow-watch-first-install 仅允许在已确认没有旧 App 的 Watch 上首次安装；
iPhone 的原位升级和原 Team 校验仍然保留。
自动选择会排除 Beta、RC、Preview、Seed 及其他预发布 Xcode。
若确实要临时使用预发布版，必须显式设置 WRIST_DEVELOPER_DIR。
脚本不会把 Team ID、UDID、账号或凭据写入仓库。

The script auto-selects one connected iPhone, one connected Apple Watch,
and one Apple Development identity. Automatic Xcode selection rejects Beta,
RC, preview, seed, and other pre-release products. Set WRIST_DEVELOPER_DIR
explicitly for one run if a pre-release Xcode is intentional. Reviewed upgrades
may use exact iPhone and Watch Bundle identifiers from ignored Local.xcconfig.
Nothing is uploaded.
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

read_config_setting() {
  local key="$1"
  local shared_config="${2:-$SHARED_CONFIG}"
  local local_config="${3:-$LOCAL_CONFIG}"
  /usr/bin/sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\\1/p" \
    "$shared_config" "$local_config" 2>/dev/null \
    | /usr/bin/tail -n 1
}

resolve_bundle_identifiers() {
  local shared_config="${1:-$SHARED_CONFIG}"
  local local_config="${2:-$LOCAL_CONFIG}"

  BUNDLE_PREFIX="$(
    read_config_setting WRISTREMOTE_BUNDLE_PREFIX "$shared_config" "$local_config"
  )"

  IOS_BUNDLE_ID="$(
    read_config_setting WRISTREMOTE_IOS_BUNDLE_IDENTIFIER "$shared_config" "$local_config"
  )"
  case "$IOS_BUNDLE_ID" in
    '$(WRISTREMOTE_BUNDLE_PREFIX).ios'|'')
      IOS_BUNDLE_ID="${BUNDLE_PREFIX}.ios"
      ;;
  esac

  WATCH_BUNDLE_ID="$(
    read_config_setting WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER "$shared_config" "$local_config"
  )"
  case "$WATCH_BUNDLE_ID" in
    '$(WRISTREMOTE_IOS_BUNDLE_IDENTIFIER).watchkitapp'|'')
      WATCH_BUNDLE_ID="${IOS_BUNDLE_ID}.watchkitapp"
      ;;
  esac

  EXISTING_INSTALL_REQUIRED="$(
    read_config_setting WRISTREMOTE_EXISTING_INSTALL_REQUIRED "$shared_config" "$local_config"
  )"
  EXISTING_INSTALL_REQUIRED="${EXISTING_INSTALL_REQUIRED:u}"
  [[ -n "$EXISTING_INSTALL_REQUIRED" ]] || EXISTING_INSTALL_REQUIRED='NO'
  EXISTING_INSTALL_TEAM_ID="$(
    read_config_setting WRISTREMOTE_EXISTING_INSTALL_TEAM_ID "$shared_config" "$local_config"
  )"
}

validate_bundle_identifier() {
  local value="$1"
  local label="$2"
  local normalized="${value:l}"

  [[ "$value" =~ '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$' ]] \
    || die "$label 必须是有效的反向域名 Bundle 标识。"
  [[ "$normalized" != *'.example.'* && "$normalized" != example.* ]] \
    || die "$label 仍是示例占位值；已阻止真机安装。"
  [[ "$normalized" != *'.invalid'* && "$normalized" != *'replace_'* ]] \
    || die "$label 仍是无效占位值；已阻止真机安装。"
}

validate_mobile_bundle_identifiers() {
  validate_bundle_identifier "$IOS_BUNDLE_ID" 'iPhone Bundle ID'
  validate_bundle_identifier "$WATCH_BUNDLE_ID" 'Apple Watch Bundle ID'
  [[ "$WATCH_BUNDLE_ID" == "${IOS_BUNDLE_ID}.watchkitapp" ]] \
    || die 'Apple Watch Bundle ID 必须严格位于 iPhone Bundle ID 的 .watchkitapp 命名空间。'
  [[ "$EXISTING_INSTALL_REQUIRED" == YES || "$EXISTING_INSTALL_REQUIRED" == NO ]] \
    || die 'WRISTREMOTE_EXISTING_INSTALL_REQUIRED 只接受 YES 或 NO。'
  if [[ "$EXISTING_INSTALL_REQUIRED" == YES ]]; then
    [[ "$EXISTING_INSTALL_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] \
      || die '受控升级必须配置原安装使用的 10 位 Apple Developer Team ID。'
  fi
}

validate_existing_install_team() {
  local selected_team_id="$1"
  if [[ "$EXISTING_INSTALL_REQUIRED" == YES \
        && "$selected_team_id" != "$EXISTING_INSTALL_TEAM_ID" ]]; then
    die '当前 Apple Development Team 与受控升级记录的原安装 Team 不一致。'
  fi
}

classify_installed_apps() {
  local apps_json="$1"
  local expected_bundle_id="$2"
  local label="$3"
  local existing_required="$4"

  /usr/bin/python3 - \
      "$apps_json" "$expected_bundle_id" "$label" "$existing_required" <<'PY'
import json
import sys

path, expected, label, existing_required = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)

if document.get("info", {}).get("outcome") != "success":
    print(f"{label} 的已安装 App 身份查询未成功。", file=sys.stderr)
    raise SystemExit(2)

apps = document.get("result", {}).get("apps", [])
exact = [item for item in apps if item.get("bundleIdentifier") == expected]

def is_related(item):
    bundle = str(item.get("bundleIdentifier", "")).lower()
    expected_is_watch = expected.lower().endswith(".watchkitapp")
    candidate_is_watch = bundle.endswith(".watchkitapp")
    if expected_is_watch != candidate_is_watch:
        # An iPhone inventory may expose its embedded Watch companion. It is
        # part of the same product, not a duplicate app on the current platform.
        return False
    names = " ".join(
        str(item.get(key, ""))
        for key in ("name", "displayName", "localizedName", "executable")
    ).lower()
    compact_names = names.replace(" ", "").replace("-", "")
    return "wristremote" in bundle or "wristremote" in compact_names

related_other = [
    item
    for item in apps
    if item.get("bundleIdentifier") != expected and is_related(item)
]

if related_other:
    print(
        f"{label} 上检测到 {len(related_other)} 个不同身份的 Wrist Remote；"
        "为避免生成重复 App，已停止安装。",
        file=sys.stderr,
    )
    raise SystemExit(3)

if exact:
    print("exact")
    raise SystemExit(0)

if existing_required == "YES":
    print(
        f"{label} 上没有找到经过审核的现有安装；已阻止把升级误执行为新装。",
        file=sys.stderr,
    )
    raise SystemExit(4)

print("fresh")
PY
}

verify_existing_install_identity() {
  local udid="$1"
  local bundle_id="$2"
  local label="$3"
  local slug="$4"
  local apps_json="$TEMP_ROOT/apps-before-install-${slug}.json"
  local classification
  local require_existing="$EXISTING_INSTALL_REQUIRED"
  if [[ "$slug" == watch && "$ALLOW_WATCH_FIRST_INSTALL" == 1 ]]; then
    require_existing='NO'
  fi

  if ! /usr/bin/xcrun devicectl device info apps \
      --device "$udid" \
      --include-default-apps \
      --timeout 30 \
      --quiet \
      --json-output "$apps_json"; then
    die "$label 的已安装 App 身份无法读取；已停止安装。"
  fi

  if ! classification="$(
    classify_installed_apps \
      "$apps_json" "$bundle_id" "$label" "$require_existing"
  )"; then
    die "$label 的原位升级身份校验失败。"
  fi

  [[ "$slug" != watch ]] || WATCH_INSTALL_CLASSIFICATION="$classification"

  if [[ "$classification" == exact ]]; then
    print -u2 -- "$label 已确认同一 App 身份，将执行原位升级。"
  else
    print -u2 -- "$label 未发现同名旧安装，将执行首次安装。"
  fi
}

verify_existing_profile_identity() {
  local bundle_id="$1"
  local team_id="$2"
  local label="$3"
  local decoded_profile_directory="${4:-}"

  [[ "$EXISTING_INSTALL_REQUIRED" == YES ]] || return 0

  /usr/bin/python3 - \
      "$bundle_id" "$team_id" "$label" "$decoded_profile_directory" \
      "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
      "$HOME/Library/MobileDevice/Provisioning Profiles" <<'PY'
import datetime
import pathlib
import plistlib
import subprocess
import sys

bundle_id, team_id, label, test_profile_directory, *roots = sys.argv[1:]
if test_profile_directory:
    roots = [test_profile_directory]
now = datetime.datetime.now(datetime.timezone.utc)
matching_bundle = 0
matching_current_team = 0

for root_value in roots:
    root = pathlib.Path(root_value)
    if not root.is_dir():
        continue
    for path in root.iterdir():
        accepted_suffixes = (
            {".plist"}
            if test_profile_directory
            else {".mobileprovision", ".provisionprofile"}
        )
        if path.suffix not in accepted_suffixes:
            continue
        try:
            if test_profile_directory:
                decoded = path.read_bytes()
            else:
                decoded = subprocess.run(
                    ["/usr/bin/security", "cms", "-D", "-i", str(path)],
                    check=True,
                    capture_output=True,
                ).stdout
            profile = plistlib.loads(decoded)
        except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException):
            continue

        entitlements = profile.get("Entitlements", {})
        application_id = entitlements.get("application-identifier", "")
        profile_teams = profile.get("TeamIdentifier", [])
        suffix = application_id.split(".", 1)[1] if "." in application_id else ""
        if suffix != bundle_id:
            continue
        matching_bundle += 1

        expires = profile.get("ExpirationDate")
        if not isinstance(expires, datetime.datetime):
            continue
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        # Historical profiles prove identity continuity, not permission to
        # install today. A renewed build is checked for expiry separately by
        # verify_profile before installation.
        if team_id not in profile_teams:
            continue
        if application_id != f"{team_id}.{bundle_id}":
            continue
        matching_current_team += 1

if matching_current_team == 0:
    if matching_bundle:
        print(
            f"{label} 的历史描述文件不属于当前 Apple Development Team。",
            file=sys.stderr,
        )
    else:
        print(
            f"没有找到 {label} 的历史描述文件，无法证明这是同一 App 身份。",
            file=sys.stderr,
        )
    raise SystemExit(2)

print(f"{label} 的历史 Bundle 与当前 Team 已确认；新构建仍须通过有效期检查。", file=sys.stderr)
PY
}

verify_mobile_install_targets() {
  verify_existing_install_identity \
    "$WATCH_UDID" "$WATCH_BUNDLE_ID" 'Apple Watch' watch
  verify_existing_install_identity \
    "$IPHONE_UDID" "$IOS_BUNDLE_ID" iPhone iphone
}

verify_mobile_signing_continuity() {
  if [[ "$EXISTING_INSTALL_REQUIRED" == YES ]] && command -v ideviceinstaller >/dev/null 2>&1; then
    # The device's signed entitlements are stronger evidence than a cached
    # provisioning profile, which may be removed during normal Xcode cleanup.
    /usr/bin/python3 "$SCRIPT_DIR/lib/installed-app-identity.py" \
      --udid "$IPHONE_HARDWARE_UDID" --bundle "$IOS_BUNDLE_ID" --team "$TEAM_ID" \
      || die 'iPhone 现装签名身份不符合受控升级记录。'
  else
    verify_existing_profile_identity "$IOS_BUNDLE_ID" "$TEAM_ID" 'iPhone 伴侣 App'
  fi
  if [[ "$WATCH_INSTALL_CLASSIFICATION" == fresh && "$ALLOW_WATCH_FIRST_INSTALL" == 1 ]]; then
    print -- 'Watch 已确认无旧 App；本次明确允许首次安装，仍校验新包 Team 与设备。'
  else
    verify_existing_profile_identity "$WATCH_BUNDLE_ID" "$TEAM_ID" 'Apple Watch App'
  fi
}

for argument in "$@"; do
  case "$argument" in
    --dry-run)
      DRY_RUN=1
      ;;
    --allow-watch-first-install)
      ALLOW_WATCH_FIRST_INSTALL=1
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
  local active search_root

  # Tests inject an isolated applications root. Normal invocations always use
  # xcode-select plus /Applications and never mutate the global selection.
  if (( $# == 2 )); then
    active="$1"
    search_root="$2"
  else
    active="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    search_root='/Applications'
  fi
  [[ -n "$active" ]] && candidates+=("$active")
  candidates+=("$search_root"/Xcode*.app/Contents/Developer(N))

  /usr/bin/python3 - "$active" "${candidates[@]}" <<'PY'
import os
import pathlib
import plistlib
import re
import subprocess
import sys

active = os.path.realpath(sys.argv[1]) if sys.argv[1] else ""
candidates = sys.argv[2:]
prerelease_pattern = re.compile(
    r"(?:^|[^a-z0-9])(?:beta|release[ _-]*candidate|rc(?:[ _-]*\d+)?|"
    r"preview|developer[ _-]*preview|seed|pre[ _-]?release)(?:$|[^a-z0-9])",
    re.IGNORECASE,
)


def read_plist(path):
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
            return value if isinstance(value, dict) else {}
    except (OSError, plistlib.InvalidFileException):
        return {}


def version_tuple(value):
    match = re.fullmatch(r"(\d+(?:\.\d+){0,3})(?:\s.*)?", value.strip())
    if not match:
        return None
    parts = tuple(int(part) for part in match.group(1).split("."))
    return parts + (0,) * (4 - len(parts))


def inspect_candidate(raw_path):
    developer = pathlib.Path(raw_path).resolve()
    if developer.name != "Developer" or developer.parent.name != "Contents":
        return None
    app = developer.parent.parent
    if app.suffix.lower() != ".app":
        return None

    xcodebuild = developer / "usr/bin/xcodebuild"
    xcode_app = app / "Contents/MacOS/Xcode"
    info_path = app / "Contents/Info.plist"
    version_path = app / "Contents/version.plist"
    if not (xcodebuild.is_file() and os.access(xcodebuild, os.X_OK)):
        return None
    if not (xcode_app.is_file() and os.access(xcode_app, os.X_OK)):
        return None

    info = read_plist(info_path)
    product = read_plist(version_path)
    if info.get("CFBundleIdentifier") != "com.apple.dt.Xcode":
        return None

    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = str(developer)
    try:
        completed = subprocess.run(
            [str(xcodebuild), "-version"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    output = completed.stdout.strip()
    lines = output.splitlines()
    command_version = ""
    command_build = ""
    if lines:
        match = re.fullmatch(r"Xcode\s+(.+)", lines[0].strip())
        if match:
            command_version = match.group(1).strip()
    if len(lines) > 1:
        match = re.fullmatch(r"Build version\s+(.+)", lines[1].strip())
        if match:
            command_build = match.group(1).strip()

    bundle_version = str(info.get("CFBundleShortVersionString", "")).strip()
    product_build = str(product.get("ProductBuildVersion", "")).strip()
    parsed_version = version_tuple(command_version)
    if parsed_version is None or version_tuple(bundle_version) != parsed_version:
        return None
    if product_build and command_build and product_build != command_build:
        return None

    beta_plist = app / "Contents/Resources/BetaVersion.plist"
    textual_metadata = " ".join(
        str(value)
        for value in (
            app.name,
            output,
            info.get("CFBundleName", ""),
            info.get("CFBundleDisplayName", ""),
            info.get("CFBundleGetInfoString", ""),
            bundle_version,
            product_build,
        )
    )
    is_prerelease = beta_plist.is_file() or bool(
        prerelease_pattern.search(textual_metadata)
    )
    return {
        "path": str(developer),
        "resolved": os.path.realpath(developer),
        "version": parsed_version,
        "prerelease": is_prerelease,
    }


records = []
seen = set()
for candidate in candidates:
    resolved = os.path.realpath(candidate)
    if resolved in seen:
        continue
    seen.add(resolved)
    record = inspect_candidate(candidate)
    if record is not None:
        records.append(record)

active_stable = next(
    (
        record
        for record in records
        if record["resolved"] == active and not record["prerelease"]
    ),
    None,
)
if active_stable is not None:
    print(active_stable["path"])
    raise SystemExit(0)

stable = [record for record in records if not record["prerelease"]]
if stable:
    selected = max(stable, key=lambda record: record["version"])
    print(selected["path"])
    raise SystemExit(0)

if any(record["prerelease"] for record in records):
    print(
        "只找到 Beta、RC 或其他预发布 Xcode；自动选择已停止。"
        "如果确实要使用它，请只对本次运行显式设置 WRIST_DEVELOPER_DIR。",
        file=sys.stderr,
    )
else:
    print(
        "没有找到完整稳定版 Xcode。请先安装 Xcode，"
        "或临时设置 WRIST_DEVELOPER_DIR。",
        file=sys.stderr,
    )
raise SystemExit(1)
PY
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
        print(f"{label} 指定的 UDID 不存在或平台不符。", file=sys.stderr)
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
        summary = ", ".join(item.get("name", "未命名") for item in matches)
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
    # A paired Watch can drop its RSD tunnel between two otherwise read-only
    # CoreDevice calls. Refresh once and retry; never loop or weaken the lock
    # gate, because an ambiguous device state must still stop installation.
    local refresh_json="$TEMP_ROOT/lock-refresh-${slug}.json"
    print -u2 -- "$label 开发隧道短暂断开；正在执行一次只读刷新。"
    if ! /usr/bin/xcrun devicectl device info details \
        --device "$udid" \
        --timeout 30 \
        --quiet \
        --json-output "$refresh_json" \
      || ! /usr/bin/xcrun devicectl device info lockState \
        --device "$udid" \
        --timeout 30 \
        --quiet \
        --json-output "$lock_json"; then
      die "无法读取 $label 的锁定状态。"
    fi
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
      die "只读检查无法在 $label 锁定时可靠读取已安装 App；请解锁并保持屏幕唤醒后重试。"
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
      WRISTREMOTE_IOS_BUNDLE_IDENTIFIER="$IOS_BUNDLE_ID" \
      WRISTREMOTE_WATCH_BUNDLE_IDENTIFIER="$WATCH_BUNDLE_ID" \
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

case "${WRIST_INSTALLER_TEST_ENTRYPOINT:-}" in
  choose-developer-dir)
    choose_developer_dir \
      "${WRIST_INSTALLER_TEST_ACTIVE_DIR:-}" \
      "${WRIST_INSTALLER_TEST_SEARCH_ROOT:-/Applications}"
    exit
    ;;
  resolve-bundle-identifiers)
    resolve_bundle_identifiers \
      "${WRIST_INSTALLER_TEST_SHARED_CONFIG:?}" \
      "${WRIST_INSTALLER_TEST_LOCAL_CONFIG:?}"
    validate_mobile_bundle_identifiers
    print -r -- "IOS=$IOS_BUNDLE_ID"
    print -r -- "WATCH=$WATCH_BUNDLE_ID"
    print -r -- "REQUIRE_EXISTING=$EXISTING_INSTALL_REQUIRED"
    exit
    ;;
  classify-installed-apps)
    classify_installed_apps \
      "${WRIST_INSTALLER_TEST_APPS_JSON:?}" \
      "${WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID:?}" \
      '测试设备' \
      "${WRIST_INSTALLER_TEST_REQUIRE_EXISTING:-NO}"
    exit
    ;;
  validate-existing-profile)
    EXISTING_INSTALL_REQUIRED='YES'
    verify_existing_profile_identity \
      "${WRIST_INSTALLER_TEST_EXPECTED_BUNDLE_ID:?}" \
      "${WRIST_INSTALLER_TEST_TEAM_ID:?}" \
      '测试 App' \
      "${WRIST_INSTALLER_TEST_PROFILE_DIRECTORY:?}"
    exit
    ;;
  validate-existing-team)
    resolve_bundle_identifiers \
      "${WRIST_INSTALLER_TEST_SHARED_CONFIG:?}" \
      "${WRIST_INSTALLER_TEST_LOCAL_CONFIG:?}"
    validate_mobile_bundle_identifiers
    validate_existing_install_team "${WRIST_INSTALLER_TEST_TEAM_ID:?}"
    exit
    ;;
esac

command -v xcodegen >/dev/null 2>&1 \
  || die '找不到 XcodeGen。请先运行 make setup。'
[[ -f "$SHARED_CONFIG" ]] \
  || die '缺少 Config/WristRemote.xcconfig。'
[[ -f "$LOCAL_CONFIG" ]] \
  || die '缺少 Config/Local.xcconfig。请先运行 make setup 并填写唯一 Bundle 前缀。'

resolve_bundle_identifiers
[[ "$BUNDLE_PREFIX" =~ '^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$' ]] \
  || die 'WRISTREMOTE_BUNDLE_PREFIX 必须是反向域名格式，例如 org.example.wristremote。'
validate_mobile_bundle_identifiers
readonly BUNDLE_PREFIX IOS_BUNDLE_ID WATCH_BUNDLE_ID EXISTING_INSTALL_REQUIRED EXISTING_INSTALL_TEAM_ID

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
    connection_state = connection.get("state")
    pairing_state = connection.get("pairingState")
    # CoreDevice commonly reports a paired iPhone/Watch as disconnected until
    # the first details request creates its short-lived RSD tunnel. Treat that
    # state as selectable, then let preflight_device establish and verify the
    # actual development connection before any build, signing, or install.
    paired_candidate = pairing_state == "paired" and connection_state in {
        "connected",
        "disconnected",
    }
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
        "available": paired_candidate,
        "connectionState": connection_state,
        "pairingState": pairing_state,
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

preflight_device "$WATCH_UDID" 'Apple Watch' watch
preflight_device "$IPHONE_UDID" iPhone iphone

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

validate_existing_install_team "$TEAM_ID"

verify_mobile_install_targets
verify_mobile_signing_continuity

if (( DRY_RUN )); then
  verify_mobile_install_targets
  print -- '只读检查通过：未构建、未注册设备、未签名、未安装、未启动。'
  print -- '实际执行顺序：Watch 构建 → iPhone 构建 → 三包校验 → Watch 安装 → iPhone 安装 → 两端启动。'
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

# This is the final pre-install identity gate. Re-read both devices after the
# potentially long signing build so a disconnect or app-identity change fails
# closed instead of creating a second installation.
verify_mobile_install_targets
verify_mobile_signing_continuity

# Install the Watch first while its short-lived paired-device tunnel is fresh.
# The iPhone companion follows with the same verified identity and embedded
# Watch build; neither path uninstalls or looks up apps by display name.
install_and_verify \
  "$WATCH_UDID" \
  "$WATCH_APP" \
  "$WATCH_BUNDLE_ID" \
  'Apple Watch App' \
  watch
install_and_verify \
  "$IPHONE_UDID" \
  "$IPHONE_APP" \
  "$IOS_BUNDLE_ID" \
  'iPhone 伴侣 App' \
  iphone

launch_app "$IPHONE_UDID" "$IOS_BUNDLE_ID" 'iPhone 伴侣 App' iphone
launch_app "$WATCH_UDID" "$WATCH_BUNDLE_ID" 'Apple Watch App' watch

print -- '完成：iPhone 与 Apple Watch 已重新签名、安装并启动。'
print -- 'Wrist Remote 使用独立 Bundle ID、协议与存储，不读取或修改其他遥控器配置。'
