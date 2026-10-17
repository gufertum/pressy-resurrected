#!/usr/bin/env bash
# Installs the latest pressy release from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/gufertum/pressy-resurrected/main/get-pressy.sh | bash
# Downloads the release zip, verifies its sha256, unpacks it and runs its scripts/install.sh.
# Options (environment): PRESSY_VERSION=0.4.0 for a specific release, PRESSY_RELEASE_URL to download
# from another location (a folder holding the zip and .sha256, file:// works).
set -euo pipefail

REPO="gufertum/pressy-resurrected"

fail() { echo "pressy: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "pressy runs on macOS only"
[[ "$(uname -m)" == arm64 ]] || fail "pressy needs an Apple silicon Mac (the jack's Headset HID device)"

VERSION="${PRESSY_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$VERSION" ]] || fail "could not find the latest release of $REPO"
fi
BASE="${PRESSY_RELEASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
ZIP="pressy-$VERSION-macos-arm64.zip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "downloading pressy $VERSION"
curl -fsSL --max-time 120 -o "$WORK/$ZIP" "$BASE/$ZIP" || fail "download failed: $BASE/$ZIP"
curl -fsSL --max-time 20 -o "$WORK/$ZIP.sha256" "$BASE/$ZIP.sha256" || fail "download failed: $BASE/$ZIP.sha256"
(cd "$WORK" && shasum -a 256 -c "$ZIP.sha256" >/dev/null) || fail "checksum mismatch for $ZIP, not installing"

ditto -x -k "$WORK/$ZIP" "$WORK"
# curl sets no quarantine flag; a copy that went through a browser would have one.
xattr -dr com.apple.quarantine "$WORK/pressy-$VERSION" 2>/dev/null || true
bash "$WORK/pressy-$VERSION/scripts/install.sh"
