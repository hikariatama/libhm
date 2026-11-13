#!/bin/bash
# Never execute a Homebrew or PATH-provided XcodeGen in a release build.
set -euo pipefail
version=2.46.0
digest=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
cache="${LIBHM_TOOLS_CACHE:-$HOME/Library/Caches/libhm-tools}"
mkdir -p "$cache"
archive="$cache/xcodegen-$version.zip"
staging="$(mktemp -d "${TMPDIR:-/tmp}/libhm-xcodegen.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
verify() {
  printf '%s  %s\n' "$digest" "$1" | shasum -a 256 --check --status
}
if [[ ! -f "$archive" ]]; then
  curl --fail --silent --show-error --location \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" \
    --output "$staging/xcodegen.zip"
  verify "$staging/xcodegen.zip"
  cp "$staging/xcodegen.zip" "$archive"
fi
# Check cached bytes as well; fail closed instead of accepting a different binary.
verify "$archive"
unzip -q "$archive" -d "$staging"
"$staging/xcodegen/bin/xcodegen" "$@"
