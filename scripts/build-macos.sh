#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly APP_DIR="$REPO_ROOT/apps/WristRemoteBridge"
readonly BUILD_ROOT="$APP_DIR/.build/Product"
readonly PRODUCT="$BUILD_ROOT/Build/Products/Release/WristRemoteBridge.app"

install_app=0
for argument in "$@"; do
  case "$argument" in
    --install) install_app=1 ;;
    -h|--help)
      print -- "usage: scripts/build-macos.sh [--install]"
      exit 0
      ;;
    *) print -u2 -- "unknown argument: $argument"; exit 64 ;;
  esac
done

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
identity="${WRIST_CODESIGN_IDENTITY:--}"
/usr/bin/codesign --force --options runtime --timestamp=none --sign "$identity" "$PRODUCT"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PRODUCT"

if (( install_app )); then
  install_dir="${WRISTREMOTE_INSTALL_DIR:-$HOME/Applications}"
  target="$install_dir/WristRemoteBridge.app"
  /bin/mkdir -p "$install_dir"
  if [[ -e "$target" ]]; then
    backup="$install_dir/WristRemoteBridge.backup-$(/bin/date +%Y%m%d-%H%M%S).app"
    /bin/mv "$target" "$backup"
    print -- "Previous app moved to: $backup"
  fi
  /usr/bin/ditto "$PRODUCT" "$target"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"
  /usr/bin/open "$target"
  print -- "Installed and opened: $target"
else
  print -- "Built and locally signed: $PRODUCT"
fi
