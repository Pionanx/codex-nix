#!/usr/bin/env bash
#
# Update Codex to an official GitHub release.
#
# Usage:
#   ./scripts/update.sh              # update to latest stable release
#   ./scripts/update.sh --check      # fail if sources.json is not latest
#   ./scripts/update.sh 0.144.1      # update to a specific release

set -euo pipefail

REPO="openai/codex"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_JSON="${SCRIPT_DIR}/../sources.json"
CHECKSUM_ASSET="codex-package_SHA256SUMS"

PLATFORMS=(
  "aarch64-apple-darwin"
  "aarch64-unknown-linux-musl"
  "x86_64-apple-darwin"
  "x86_64-unknown-linux-musl"
)

usage() {
  sed -n '2,8s/^# \{0,1\}//p' "$0"
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

github_api() {
  local url="$1"
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local args=(
    --fail
    --silent
    --show-error
    --location
    --retry 3
    --header "Accept: application/vnd.github+json"
    --header "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -z "$token" ]] \
    && command -v gh >/dev/null 2>&1 \
    && gh auth status --hostname github.com >/dev/null 2>&1; then
    gh api "${url#https://api.github.com/}"
    return
  fi

  if [[ -n "$token" ]]; then
    args+=(--header "Authorization: Bearer ${token}")
  fi

  curl "${args[@]}" "$url"
}

download_file() {
  local url="$1"
  local output="$2"

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --output "$output" \
    "$url"
}

normalize_version() {
  local version="$1"

  version="${version#rust-v}"
  version="${version#v}"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] \
    || die "invalid version: $1"

  printf '%s\n' "$version"
}

current_version() {
  jq --exit-status --raw-output '.version' "$SOURCES_JSON"
}

asset_hash() {
  local manifest="$1"
  local asset="$2"
  local hex

  hex=$(awk -v asset="$asset" '
    $2 == asset && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
      print tolower($1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$manifest") || die "missing checksum for ${asset}"

  nix hash convert --hash-algo sha256 --to sri "$hex"
}

require_command curl
require_command jq
require_command nix

mode="update"
requested="latest"

case "$#" in
  0)
    ;;
  1)
    case "$1" in
      --check)
        mode="check"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        requested=$(normalize_version "$1")
        ;;
    esac
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ "$requested" == "latest" ]]; then
  release_json=$(github_api "https://api.github.com/repos/${REPO}/releases/latest")
else
  release_json=$(github_api "https://api.github.com/repos/${REPO}/releases/tags/rust-v${requested}")
fi

tag=$(jq --exit-status --raw-output '.tag_name' <<<"$release_json") \
  || die "release metadata does not contain a tag"
[[ "$tag" == rust-v* ]] || die "unexpected upstream tag: ${tag}"

new_version=$(normalize_version "$tag")
if [[ "$requested" != "latest" && "$requested" != "$new_version" ]]; then
  die "requested ${requested}, but GitHub returned ${tag}"
fi

if [[ "$requested" == "latest" ]]; then
  jq --exit-status '.draft == false and .prerelease == false' <<<"$release_json" >/dev/null \
    || die "GitHub latest release is not a stable published release"
fi

checksum_url=$(
  jq --exit-status --raw-output --arg asset "$CHECKSUM_ASSET" '
    .assets[] | select(.name == $asset) | .browser_download_url
  ' <<<"$release_json"
) || die "release ${tag} does not contain ${CHECKSUM_ASSET}"

checksum_digest=$(
  jq --exit-status --raw-output --arg asset "$CHECKSUM_ASSET" '
    .assets[] | select(.name == $asset) | .digest
  ' <<<"$release_json"
) || die "release ${tag} does not publish a digest for ${CHECKSUM_ASSET}"

[[ "$checksum_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] \
  || die "invalid digest for ${CHECKSUM_ASSET}: ${checksum_digest}"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

manifest="${tmp_dir}/${CHECKSUM_ASSET}"
desired_sources="${tmp_dir}/sources.json"

download_file "$checksum_url" "$manifest"

expected_manifest_hash=$(
  nix hash convert \
    --hash-algo sha256 \
    --to sri \
    "${checksum_digest#sha256:}"
)
actual_manifest_hash=$(nix hash file --type sha256 "$manifest")
[[ "$actual_manifest_hash" == "$expected_manifest_hash" ]] \
  || die "checksum manifest digest mismatch"

for platform in "${PLATFORMS[@]}"; do
  asset="codex-package-${platform}.tar.gz"
  jq --exit-status --arg asset "$asset" \
    'any(.assets[]; .name == $asset)' <<<"$release_json" >/dev/null \
    || die "release ${tag} does not contain ${asset}"
done

hash_aarch64_darwin=$(asset_hash "$manifest" "codex-package-aarch64-apple-darwin.tar.gz")
hash_aarch64_linux=$(asset_hash "$manifest" "codex-package-aarch64-unknown-linux-musl.tar.gz")
hash_x86_64_darwin=$(asset_hash "$manifest" "codex-package-x86_64-apple-darwin.tar.gz")
hash_x86_64_linux=$(asset_hash "$manifest" "codex-package-x86_64-unknown-linux-musl.tar.gz")

jq --null-input \
  --arg version "$new_version" \
  --arg hash_aarch64_darwin "$hash_aarch64_darwin" \
  --arg hash_aarch64_linux "$hash_aarch64_linux" \
  --arg hash_x86_64_darwin "$hash_x86_64_darwin" \
  --arg hash_x86_64_linux "$hash_x86_64_linux" \
  '{
    version: $version,
    hashes: {
      "aarch64-apple-darwin": $hash_aarch64_darwin,
      "aarch64-unknown-linux-musl": $hash_aarch64_linux,
      "x86_64-apple-darwin": $hash_x86_64_darwin,
      "x86_64-unknown-linux-musl": $hash_x86_64_linux
    }
  }' >"$desired_sources"

current=$(current_version)
echo "Current version: ${current}"
echo "Latest version:  ${new_version}"

if cmp -s "$SOURCES_JSON" "$desired_sources"; then
  echo "Already up to date."
  exit 0
fi

if [[ "$mode" == "check" ]]; then
  echo "sources.json does not match the latest stable Codex release." >&2
  diff -u "$SOURCES_JSON" "$desired_sources" >&2 || true
  exit 1
fi

mv "$desired_sources" "$SOURCES_JSON"
echo "Updated sources.json to Codex ${new_version}."
echo "Run 'nix flake check --print-build-logs' to verify the package."
