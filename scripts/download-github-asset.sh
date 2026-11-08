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

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$expected_sha256" "$temporary_file" | sha256sum --check --strict
else
  printf '%s  %s\n' "$expected_sha256" "$temporary_file" | shasum -a 256 --check
fi

mv -f -- "$temporary_file" "$output_file"
echo "Verified official GitHub release asset: $repository/$asset_id"
