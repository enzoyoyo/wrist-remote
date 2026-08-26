#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/WristRemoteSecurity.XXXXXX")"
WORKTREE_ROOT="$TEMP_ROOT/worktree"
readonly SCRIPT_DIR REPO_ROOT TEMP_ROOT WORKTREE_ROOT

cleanup() {
  local allowed_prefix="${TMPDIR:-/tmp}/WristRemoteSecurity."
  if [[ -d "$TEMP_ROOT" && "$TEMP_ROOT" == "$allowed_prefix"* ]]; then
    /bin/rm -rf -- "$TEMP_ROOT"
  else
    printf '%s\n' "Security-check temporary directory failed its cleanup guard." >&2
  fi
}
trap cleanup EXIT INT TERM

for required_command in git gitleaks python3; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf '%s\n' "Required security scanner is missing: $required_command" >&2
    exit 1
  fi
done

/bin/mkdir -p "$WORKTREE_ROOT"

git_mode=0
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_mode=1
elif [[ -e "$REPO_ROOT/.git" ]]; then
  printf '%s\n' "Git metadata exists but cannot be read; security checks failed closed." >&2
  exit 1
elif [[ "${CI:-}" == true ]]; then
  printf '%s\n' "CI security checks require a Git checkout so history can be scanned." >&2
  exit 1
else
  printf '%s\n' "No Git repository yet; scanning the publishable worktree and skipping history."
fi

if (( git_mode )) && [[ "${CI:-}" == true ]] \
  && ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  printf '%s\n' "CI security checks require a checked-out commit and complete history." >&2
  exit 1
fi

if ! python3 - "$REPO_ROOT" "$WORKTREE_ROOT" "$git_mode" <<'PY'
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import ipaddress
import re
import shutil
import stat
import struct
import subprocess
import sys
import zlib
from urllib.parse import urlsplit


MAX_FILE_BYTES = 5 * 1024 * 1024
REPO_ROOT = Path(sys.argv[1]).resolve()
WORKTREE_ROOT = Path(sys.argv[2]).resolve()
GIT_MODE = sys.argv[3] == "1"

IGNORED_PARTS = {
    ".build",
    ".codex",
    ".security-scan",
    ".swiftpm",
    ".wrangler",
    "Bugs",
    "DerivedData",
    "Screenshots",
    "artifacts",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "screenshots",
    "xcuserdata",
}
IGNORED_EXACT = {
    "Config/Local.xcconfig",
    "apps/WristRemote/Generated",
    "apps/WristRemote/WristRemote.xcodeproj",
    "apps/WristRemoteBridge/Generated",
    "apps/WristRemoteBridge/WristRemoteBridge.xcodeproj",
    "apps/WristRemoteRelay/worker-configuration.d.ts",
}
IGNORED_NAMES = {
    ".DS_Store",
    ".envrc",
    ".npmrc",
    "coverage.json",
    "findings.json",
    "report.md",
    "scan-manifest.json",
}
FORBIDDEN_SUFFIXES = {
    ".app",
    ".cer",
    ".crt",
    ".der",
    ".dmg",
    ".ipa",
    ".ips",
    ".jks",
    ".key",
    ".keychain",
    ".keychain-db",
    ".keystore",
    ".log",
    ".mobileprovision",
    ".p12",
    ".p8",
    ".pem",
    ".pkg",
    ".profdata",
    ".profile",
    ".provisionprofile",
    ".sarif",
    ".trace",
    ".xcarchive",
    ".xcresult",
}
REQUIRED_IGNORE_RULES = {
    "**/.build/",
    "**/node_modules/",
    ".dev.vars",
    ".env",
    "*.ipa",
    "*.keychain",
    "*.mobileprovision",
    "*.xcarchive/",
    "Config/Local.xcconfig",
    "xcuserdata/",
}

CONTENT_PATTERNS = {
    "absolute local filesystem path": re.compile(
        rb"(?i)(?:/(?:Users|home)/[^\s\"']+|/var/folders/[^\s\"']+|[A-Z]:\\Users\\[^\s\"']+)"
    ),
    "private-key material": re.compile(
        rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
    ),
    "GitHub access token": re.compile(
        rb"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"
    ),
    "AWS access-key identifier": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "Slack access token": re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{16,}\b"),
    "live payment secret": re.compile(rb"\bsk_live_[A-Za-z0-9]{16,}\b"),
    "Google API key": re.compile(rb"\bAIza[A-Za-z0-9_-]{30,}\b"),
    "literal secret assignment": re.compile(
        rb"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|cloudflare_api_token)\b"
        rb"\s*[:=]\s*[\"'](?!REPLACE|CHANGE|EXAMPLE|\$\{|<)[^\"']{8,}[\"']"
    ),
    "literal Bearer credential": re.compile(
        rb"(?i)Authorization\s*:\s*Bearer\s+(?!\$|\{|<|REPLACE|EXAMPLE)[A-Za-z0-9._~-]{12,}"
    ),
    "Apple development Team ID": re.compile(
        rb"(?im)^\s*(?:DEVELOPMENT_TEAM|WRISTREMOTE_DEVELOPMENT_TEAM|WRIST_TEAM_ID)"
        rb"\s*[:=]\s*[\"']?([A-Z0-9]{10})[\"']?\s*(?:#.*)?$"
    ),
    "Apple device identifier": re.compile(
        rb"(?i)\b(?:WRIST_(?:IPHONE|WATCH)_UDID|UDID|DEVICE_ID)\b\s*[:=]\s*[\"']?"
        rb"(?:[0-9A-F]{24,}|[0-9A-F]{8,}(?:-[0-9A-F]{4,})+)"
    ),
    "Cloudflare account or zone identifier": re.compile(
        rb"(?i)[\"']?(?:account_id|zone_id)[\"']?\s*[:=]\s*[\"'][0-9a-f]{32}[\"']"
    ),
}

EMAIL_PATTERN = re.compile(
    rb"(?i)(?<![A-Z0-9._%+-])([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})(?![A-Z0-9._%+-])"
)
IPV4_PATTERN = re.compile(
    rb"(?<![0-9A-Fa-f:.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9A-Fa-f:.])"
)
IPV6_CANDIDATE_PATTERN = re.compile(
    rb"(?i)(?<![0-9A-F:.])(?=[0-9A-F:.]*:[0-9A-F:.]*:)[0-9A-F:.]{2,}(?![0-9A-F:.])"
)
ACTIONS_USE_PATTERN = re.compile(
    rb"(?m)^\s*uses:\s*[A-Z0-9_.-]+/[A-Z0-9_.-]+(?:/[A-Z0-9_.-]+)*@([^\s#]+)",
    re.IGNORECASE,
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_ALLOWED_CHUNKS = {b"IHDR", b"sRGB", b"IDAT", b"IEND"}
URL_PATTERN = re.compile(
    rb"(?i)https://(?:localhost|[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?|\[[0-9A-F:.]+\])"
    rb"(?::[0-9]{1,5})?(?:/[A-Z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?"
)
ALLOWED_EMAIL_DOMAINS = {"apache.org", "example.invalid"}
ALLOWED_URL_HOST_SUFFIXES = {
    "apache.org",
    "apple.com",
    "cloudflare.com",
    "example.invalid",
    "example",
    "fsf.org",
    "github.com",
    "githubusercontent.com",
    "gnu.org",
    "internal",
    "localhost",
    "npmjs.org",
    "openai.com",
    "opensource.org",
    "spdx.org",
    "test",
    "w3.org",
}
ALLOWED_GITHUB_OWNERS = {
    "actions",
    "apple",
    "burntsushi",
    "cloudflare",
    "github",
    "gitleaks",
    "openai",
    "owner",
    "swiftlang",
    "your_organization",
    "yonaskolb",
}

violations: set[tuple[str, str]] = set()


def report(path: str, category: str) -> None:
    display_path = path
    if category == "unsafe repository path":
        display_path = "<redacted-path>"
    violations.add((display_path, category))


def ignored_for_nongit(relative: str) -> bool:
    path = PurePosixPath(relative)
    parts = set(path.parts)
    if parts & IGNORED_PARTS:
        return True
    if relative in IGNORED_EXACT or any(
        relative.startswith(prefix + "/") for prefix in IGNORED_EXACT
    ):
        return True
    if path.name in IGNORED_NAMES:
        return True
    if path.name == ".env.example" or path.name == ".dev.vars.example":
        return False
    if path.name == ".env" or path.name.startswith(".env."):
        return True
    if path.name == ".dev.vars" or path.name.startswith(".dev.vars."):
        return True
    return any(relative.endswith(suffix) for suffix in FORBIDDEN_SUFFIXES)


def candidate_paths() -> list[str]:
    if GIT_MODE:
        output = subprocess.run(
            [
                "git",
                "-C",
                str(REPO_ROOT),
                "ls-files",
                "-co",
                "--exclude-standard",
                "--deduplicate",
                "-z",
            ],
            check=True,
            capture_output=True,
        ).stdout
        return sorted({os.fsdecode(item) for item in output.split(b"\0") if item})

    result: list[str] = []
    for current, directory_names, file_names in os.walk(
        REPO_ROOT, topdown=True, followlinks=False
    ):
        current_path = Path(current)
        kept_directories: list[str] = []
        for directory_name in directory_names:
            candidate = current_path / directory_name
            relative = candidate.relative_to(REPO_ROOT).as_posix()
            if candidate.is_symlink():
                result.append(relative)
            elif not ignored_for_nongit(relative):
                kept_directories.append(directory_name)
        directory_names[:] = kept_directories
        for file_name in file_names:
            candidate = current_path / file_name
            relative = candidate.relative_to(REPO_ROOT).as_posix()
            if not ignored_for_nongit(relative):
                result.append(relative)
    return sorted(set(result))


def path_is_forbidden(relative: str) -> bool:
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        return True
    if set(path.parts) & IGNORED_PARTS:
        return True
    if relative in IGNORED_EXACT or any(
        relative.startswith(prefix + "/") for prefix in IGNORED_EXACT
    ):
        return True
    if path.name in IGNORED_NAMES:
        return True
    if path.name == ".env.example" or path.name == ".dev.vars.example":
        return False
    if path.name == ".env" or path.name.startswith(".env."):
        return True
    if path.name == ".dev.vars" or path.name.startswith(".dev.vars."):
        return True
    return any(relative.endswith(suffix) for suffix in FORBIDDEN_SUFFIXES)


def scan_urls(relative: str, data: bytes, scope: str) -> None:
    if relative.endswith("package-lock.json"):
        return
    for raw_url in URL_PATTERN.findall(data):
        try:
            url = raw_url.decode("ascii")
            parsed = urlsplit(url)
            host = (parsed.hostname or "").lower()
        except (UnicodeDecodeError, ValueError):
            report(scope, "unparseable HTTPS URL")
            continue
        if not host or host == "127.0.0.1":
            continue
        if not any(
            host == suffix or host.endswith("." + suffix)
            for suffix in ALLOWED_URL_HOST_SUFFIXES
        ):
            report(scope, "non-generic external URL")
            continue
        if host == "github.com":
            segments = [segment for segment in parsed.path.split("/") if segment]
            if segments and segments[0].lower() not in ALLOWED_GITHUB_OWNERS:
                report(scope, "non-generic GitHub account URL")


def scan_ip_literals(data: bytes, scope: str) -> None:
    candidates = set(IPV4_PATTERN.findall(data))
    candidates.update(IPV6_CANDIDATE_PATTERN.findall(data))
    for raw_address in candidates:
        try:
            address = ipaddress.ip_address(raw_address.decode("ascii"))
        except (UnicodeDecodeError, ValueError):
            continue

        # ipaddress classifies loopback, link-local, RFC 1918, ULA, RFC 5737,
        # 2001:db8::/32, and other non-routable documentation ranges as
        # non-global. IPv4-mapped IPv6 follows the embedded IPv4 classification.
        mapped = getattr(address, "ipv4_mapped", None)
        if mapped is not None:
            address = mapped
        if address.is_global:
            report(scope, "public IP address literal")


def scan_png(relative: str, data: bytes, scope: str) -> None:
    if relative and not relative.lower().endswith(".png"):
        report(scope, "PNG content uses a non-PNG filename")

    offset = len(PNG_SIGNATURE)
    chunk_index = 0
    saw_header = False
    saw_image_data = False
    saw_end = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        chunk_end = payload_end + 4
        if chunk_end > len(data):
            report(scope, "truncated PNG chunk")
            return

        expected_crc = struct.unpack(">I", data[payload_end:chunk_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(data[payload_start:payload_end], actual_crc)
        if actual_crc != expected_crc:
            report(scope, "PNG chunk checksum mismatch")
            return

        if chunk_type not in PNG_ALLOWED_CHUNKS:
            report(scope, "PNG contains unapproved metadata")
        if chunk_index == 0 and chunk_type != b"IHDR":
            report(scope, "PNG header is not first")
        if chunk_type == b"IHDR":
            if saw_header or length != 13:
                report(scope, "invalid PNG header")
            else:
                width, height, depth, color_type, compression, filtering, interlace = (
                    struct.unpack(">IIBBBBB", data[payload_start:payload_end])
                )
                if (
                    width < 1
                    or height < 1
                    or width > 4096
                    or height > 4096
                    or depth != 8
                    or color_type != 2
                    or compression != 0
                    or filtering != 0
                    or interlace != 0
                ):
                    report(scope, "PNG is not an opaque 8-bit RGB icon")
            saw_header = True
        elif chunk_type == b"IDAT":
            saw_image_data = True
        elif chunk_type == b"IEND":
            if length != 0:
                report(scope, "invalid PNG end chunk")
            saw_end = True
            offset = chunk_end
            break

        chunk_index += 1
        offset = chunk_end

    if not saw_header or not saw_image_data or not saw_end or offset != len(data):
        report(scope, "PNG structure is incomplete or has trailing data")


def scan_content(relative: str, data: bytes, scope: str) -> None:
    if data.startswith(PNG_SIGNATURE):
        scan_png(relative, data, scope)
        return

    # The scanner source necessarily contains its own detection expressions.
    # Gitleaks still scans this file; only this custom literal pass is skipped.
    if relative == "scripts/security-check.sh":
        return

    for category, pattern in CONTENT_PATTERNS.items():
        if pattern.search(data):
            report(scope, category)

    scan_ip_literals(data, scope)

    if relative.startswith(".github/") and relative.endswith((".yml", ".yaml")):
        for match in ACTIONS_USE_PATTERN.finditer(data):
            if re.fullmatch(rb"[0-9a-f]{40}", match.group(1)) is None:
                report(scope, "GitHub Action is not pinned to a full commit SHA")

    for match in EMAIL_PATTERN.finditer(data):
        address = match.group(1).decode("ascii", errors="ignore").lower()
        if re.fullmatch(r"[^@]+@[123]x\.(?:png|jpe?g|pdf)", address):
            continue
        domain = address.rsplit("@", 1)[-1]
        if domain not in ALLOWED_EMAIL_DOMAINS:
            report(scope, "non-generic email address")

    scan_urls(relative, data, scope)


def verify_ignore_contract() -> None:
    ignore_path = REPO_ROOT / ".gitignore"
    try:
        ignore_text = ignore_path.read_text(encoding="utf-8")
    except OSError:
        report(".gitignore", "missing or unreadable ignore policy")
        return
    for required_rule in REQUIRED_IGNORE_RULES:
        if required_rule not in ignore_text:
            report(".gitignore", f"missing required ignore rule: {required_rule}")


def copy_and_scan_worktree(paths: list[str]) -> None:
    for relative in paths:
        if path_is_forbidden(relative):
            report(relative, "forbidden repository material")
            continue

        source = REPO_ROOT / relative
        try:
            source_stat = source.lstat()
        except FileNotFoundError:
            # A deleted tracked file is not part of the publishable worktree.
            continue
        except OSError:
            report(relative, "unreadable repository material")
            continue

        if stat.S_ISLNK(source_stat.st_mode):
            report(relative, "symbolic link is not allowed in release source")
            continue
        if not stat.S_ISREG(source_stat.st_mode):
            report(relative, "non-regular repository material")
            continue
        if source_stat.st_size > MAX_FILE_BYTES:
            report(relative, "file exceeds the 5 MiB source limit")
            continue

        try:
            data = source.read_bytes()
        except OSError:
            report(relative, "unreadable repository material")
            continue

        scan_content(relative, data, relative)
        destination = WORKTREE_ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def scan_git_history() -> bool:
    if not GIT_MODE:
        return False
    has_head = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "--verify", "HEAD"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0
    if not has_head:
        return False

    object_output = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-list", "--objects", "--all"],
        check=True,
        capture_output=True,
    ).stdout
    object_paths: dict[str, set[str]] = {}
    object_ids: list[str] = []
    for row in object_output.splitlines():
        fields = row.split(b" ", 1)
        try:
            object_id = fields[0].decode("ascii")
        except UnicodeDecodeError:
            raise RuntimeError("invalid Git object identifier")
        if object_id not in object_paths:
            object_ids.append(object_id)
            object_paths[object_id] = set()
        if len(fields) == 2:
            object_paths[object_id].add(os.fsdecode(fields[1]))

    process = subprocess.Popen(
        ["git", "-C", str(REPO_ROOT), "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    try:
        for object_id in object_ids:
            process.stdin.write((object_id + "\n").encode("ascii"))
            process.stdin.flush()
            header = process.stdout.readline().decode("ascii", errors="strict").strip()
            header_fields = header.split()
            if len(header_fields) != 3:
                raise RuntimeError("unexpected Git object header")
            _, object_type, size_text = header_fields
            size = int(size_text)
            data = process.stdout.read(size)
            if len(data) != size or process.stdout.read(1) != b"\n":
                raise RuntimeError("truncated Git object stream")
            if object_type != "blob":
                continue

            relatives = object_paths.get(object_id, set())
            scope = f"history blob {object_id[:12]}"
            if any(path_is_forbidden(relative) for relative in relatives):
                report(scope, "forbidden material exists in Git history")
                continue
            if size > MAX_FILE_BYTES:
                report(scope, "historical blob exceeds the 5 MiB source limit")
                continue
            scan_relative = next(iter(relatives)) if len(relatives) == 1 else ""
            scan_content(scan_relative, data, scope)
    finally:
        process.stdin.close()
        process.stdout.close()
        return_code = process.wait()
        if return_code != 0:
            raise RuntimeError("Git object scanner failed")
    return True


try:
    verify_ignore_contract()
    paths = candidate_paths()
    copy_and_scan_worktree(paths)
    history_scanned = scan_git_history()
except Exception as error:
    print(
        f"Security scanner failed closed ({type(error).__name__}).",
        file=sys.stderr,
    )
    raise SystemExit(2)

if violations:
    for path, category in sorted(violations)[:50]:
        print(f"blocked: {path}: {category}", file=sys.stderr)
    if len(violations) > 50:
        print(
            f"blocked: {len(violations) - 50} additional violation(s) suppressed",
            file=sys.stderr,
        )
    raise SystemExit(1)

print(f"Publishable worktree files checked: {len(paths)}")
print(f"Custom Git history scan: {'complete' if history_scanned else 'not available'}")
PY
then
  printf '%s\n' "Repository privacy policy check failed." >&2
  exit 1
fi

if ! gitleaks dir "$WORKTREE_ROOT" \
  --no-banner \
  --redact=100 \
  --exit-code=1 \
  --max-target-megabytes=5 \
  --report-format=json \
  --report-path="$TEMP_ROOT/gitleaks-worktree.json"; then
  printf '%s\n' "Gitleaks worktree scan failed closed." >&2
  exit 1
fi

if (( git_mode )) && git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  if ! gitleaks git "$REPO_ROOT" \
    --no-banner \
    --redact=100 \
    --exit-code=1 \
    --log-opts=--all \
    --report-format=json \
    --report-path="$TEMP_ROOT/gitleaks-history.json"; then
    printf '%s\n' "Gitleaks Git-history scan failed closed." >&2
    exit 1
  fi
else
  printf '%s\n' "Gitleaks Git-history scan: not available before the first commit."
fi

printf '%s\n' "Repository privacy, worktree, and available-history checks passed."
