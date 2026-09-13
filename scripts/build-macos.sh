#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly APP_DIR="$REPO_ROOT/apps/WristRemoteBridge"
readonly BUILD_ROOT="$APP_DIR/.build/Product"
readonly PRODUCT="$BUILD_ROOT/Build/Products/Release/WristRemoteBridge.app"
readonly INSTALL_SAFETY="$SCRIPT_DIR/lib/macos-install-safety.zsh"

source "$INSTALL_SAFETY"

install_app=0
target_app_argument=''
while (( $# > 0 )); do
  case "$1" in
    --install)
      install_app=1
      shift
      ;;
    --target-app)
      (( $# >= 2 )) || { print -u2 -- "--target-app requires an absolute .app path"; exit 64; }
      target_app_argument="$2"
      shift 2
      ;;
    -h|--help)
      print -- "usage: scripts/build-macos.sh [--install] [--target-app /absolute/path/WristRemoteBridge.app]"
      exit 0
      ;;
    *) print -u2 -- "unknown argument: $1"; exit 64 ;;
  esac
done

if [[ -n "$target_app_argument" && "$install_app" != 1 ]]; then
  print -u2 -- "--target-app is valid only with --install"
  exit 64
fi

target=''
if (( install_app )); then
  if [[ -n "$target_app_argument" ]]; then
    target="$(wristremote_canonical_app_path "$target_app_argument")" || {
      print -u2 -- "--target-app must be a non-symlinked absolute path ending in .app"
      exit 64
    }
  else
    install_dir="${WRISTREMOTE_INSTALL_DIR:-$HOME/Applications}"
    target="$(wristremote_canonical_app_path "${install_dir:A}/WristRemoteBridge.app")" || {
      print -u2 -- "Could not resolve the default Mac app target."
      exit 64
    }
  fi

  [[ "$target" != "${PRODUCT:A}" ]] || {
    print -u2 -- "The install target cannot be the build product itself."
    exit 64
  }
  wristremote_assert_install_target_idle "$target"
fi

"$SCRIPT_DIR/doctor.sh"
cd "$APP_DIR"
xcodegen generate --spec project.yml
xcodebuild \
  -project WristRemoteBridge.xcodeproj \
  -scheme WristRemoteBridge \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_ROOT" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

[[ -d "$PRODUCT" ]] || { print -u2 -- "Mac app was not produced."; exit 1; }
wristremote_select_codesign_identity "${WRIST_CODESIGN_IDENTITY:-}"
case "$WRISTREMOTE_CODESIGN_SELECTION" in
  explicit)
    print -- "Signing the Mac app with the explicitly selected local identity."
    ;;
  apple-development)
    print -- "Signing the Mac app with the uniquely available Apple Development identity."
    ;;
  ad-hoc)
    print -- "No Apple Development identity is available; using ad-hoc signing for this local build."
    ;;
  *)
    print -u2 -- "Code-signing identity selection returned an invalid state."
    exit 1
    ;;
esac
if ! /usr/bin/codesign --force --options runtime --timestamp=none --sign "$WRISTREMOTE_SELECTED_CODESIGN_IDENTITY" "$PRODUCT" 2>/dev/null; then
  print -u2 -- "Mac app signing failed with the selected local signing mode."
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PRODUCT"

if (( install_app )); then
  [[ ! -L "$target" ]] || { print -u2 -- "Refusing to replace a symlinked app target: $target"; exit 1; }
  [[ ! -e "$target" || -d "$target" ]] || { print -u2 -- "Install target exists but is not an app directory: $target"; exit 1; }

  product_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCT/Contents/Info.plist")"
  [[ -n "$product_bundle_identifier" ]] || { print -u2 -- "Built app has no Bundle identifier."; exit 1; }
  if [[ -d "$target" ]]; then
    target_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$target_bundle_identifier" ]] || {
      print -u2 -- "Refusing to replace an app with no readable Bundle identifier: $target"
      exit 1
    }
    [[ "$target_bundle_identifier" == "$product_bundle_identifier" ]] || {
      print -u2 -- "Refusing to replace an app with a different Bundle identifier."
      print -u2 -- "Set WRISTREMOTE_BRIDGE_BUNDLE_IDENTIFIER in ignored Config/Local.xcconfig only after verifying the intended in-place upgrade target."
      exit 1
    }
  fi

  wristremote_assert_install_target_idle "$target"
  install_dir="${target:h}"
  /bin/mkdir -p "$install_dir"
  if [[ -e "$target" ]]; then
    backup="${target%.app}.backup-$(/bin/date +%Y%m%d-%H%M%S).app"
    /bin/mv "$target" "$backup"
    print -- "Previous app moved to: $backup"
  fi
  /usr/bin/ditto "$PRODUCT" "$target"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"
  installed_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")"
  [[ "$installed_bundle_identifier" == "$product_bundle_identifier" ]] || {
    print -u2 -- "Installed app Bundle identifier does not match the verified build product."
    exit 1
  }
  wristremote_assert_install_target_idle "$target"
  /usr/bin/open "$target"
  print -- "Installed and opened: $target"
else
  print -- "Built and locally signed: $PRODUCT"
fi
