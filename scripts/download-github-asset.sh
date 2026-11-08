#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" != 4 ]]; then
  echo "Usage: download-github-asset.sh owner/repo asset-id sha256 output-file" >&2
  exit 2
fi

readonly repository="$1"
readonly asset_id="$2"
readonly expected_sha256="$3"
readonly output_file="$4"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ||
      ! "$asset_id" =~ ^[0-9]+$ ||
      ! "$expected_sha256" =~ ^[a-f0-9]{64}$ ||
      -z "$output_file" || -d "$output_file" ]]; then
  echo "Invalid release asset coordinates, checksum, or output file" >&2
  exit 2
fi
: "${GITHUB_DOWNLOAD_TOKEN:?A GitHub download token is required}"

mkdir -p "$(dirname "$output_file")"
readonly temporary_file="$(mktemp "${output_file}.download.XXXXXX")"
trap 'rm -f -- "$temporary_file"' EXIT

curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --fail --silent --show-error --location \
  --retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 120 \
  --max-time 300 \
  --header "Authorization: Bearer $GITHUB_DOWNLOAD_TOKEN" \
  --header 'Accept: application/octet-stream' \
  --output "$temporary_file" \
  "https://api.github.com/repos/${repository}/releases/assets/${asset_id}"

python3 - "$expected_sha256" "$temporary_file" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[2], "rb") as asset:
    for chunk in iter(lambda: asset.read(1024 * 1024), b""):
        digest.update(chunk)
if digest.hexdigest() != sys.argv[1]:
    raise SystemExit("GitHub release asset SHA-256 mismatch")
PY

mv -f -- "$temporary_file" "$output_file"
echo "Verified official GitHub release asset: $repository/$asset_id"
