#!/bin/zsh

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly LOCAL_CONFIG="$REPO_ROOT/Config/Local.xcconfig"
readonly EXAMPLE_CONFIG="$REPO_ROOT/Config/Local.xcconfig.example"

[[ "$(uname -s)" == Darwin ]] || {
  print -u2 -- "Wrist Remote development requires macOS."
  exit 1
}

/usr/bin/xcode-select -p >/dev/null 2>&1 || {
  print -u2 -- "Install Xcode and select it with xcode-select before continuing."
  exit 1
}

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    print -- "Installing XcodeGen with Homebrew…"
    brew install xcodegen
  else
    print -u2 -- "XcodeGen is required. Install it from https://github.com/yonaskolb/XcodeGen."
    exit 1
  fi
fi

if ! command -v rg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    print -- "Installing ripgrep with Homebrew…"
    brew install ripgrep
  else
    print -u2 -- "ripgrep is required. Install it before continuing."
    exit 1
  fi
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    print -- "Installing Gitleaks with Homebrew…"
    brew install gitleaks
  else
    print -u2 -- "Gitleaks is required for publication checks. Install it before continuing."
    exit 1
  fi
fi

command -v node >/dev/null 2>&1 || {
  print -u2 -- "Node.js 24 or newer is required for the optional relay."
  exit 1
}
node -e '
  const major = Number(process.versions.node.split(".")[0]);
  if (!Number.isInteger(major) || major < 24) process.exit(1);
' >/dev/null 2>&1 || {
  print -u2 -- "Node.js 24 or newer is required for the optional relay."
  exit 1
}
command -v npm >/dev/null 2>&1 || {
  print -u2 -- "npm is required for the optional relay."
  exit 1
}

if [[ ! -f "$LOCAL_CONFIG" ]]; then
  /bin/cp "$EXAMPLE_CONFIG" "$LOCAL_CONFIG"
  /bin/chmod 600 "$LOCAL_CONFIG"
  print -- "Created ignored local configuration: Config/Local.xcconfig"
fi

(
  cd "$REPO_ROOT/apps/WristRemote"
  xcodegen generate --spec project.yml
)
(
  cd "$REPO_ROOT/apps/WristRemoteBridge"
  xcodegen generate --spec project.yml
)
(
  cd "$REPO_ROOT/apps/WristRemoteRelay"
  npm ci
)

print -- "Setup complete. Run 'make doctor', then edit Config/Local.xcconfig for device signing."
