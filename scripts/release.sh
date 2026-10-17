#!/usr/bin/env bash
# Builds a release: dist/pressy-<version>-macos-arm64.zip and its .sha256, signed with the local
# certificate. Every release carries the same signature, so users keep their privacy grants on updates.
# Contents: pressy-<version>/{bin/pressy, Pressy.app, config.example.yaml, scripts/, README.md, LICENSE}.
set -euo pipefail

SIGN_IDENTITY="${PRESSY_SIGN_IDENTITY:-pressy local signing}"
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/pressy/main.swift)"
[[ -n "$VERSION" ]] || { echo "error: no version in Sources/pressy/main.swift" >&2; exit 1; }
security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\"" \
  || { echo "error: no \"$SIGN_IDENTITY\" identity; releases are never ad-hoc signed (make cert)" >&2; exit 1; }

NAME="pressy-$VERSION"
STAGE="dist/$NAME"
ZIP="dist/$NAME-macos-arm64.zip"
rm -rf "$STAGE" "$ZIP" "$ZIP.sha256"

swift build -c release --arch arm64
install -d "$STAGE/bin" "$STAGE/scripts" "$STAGE/Pressy.app/Contents/MacOS"
install -m 755 .build/release/pressy "$STAGE/bin/pressy"
install -m 755 .build/release/PressyBar "$STAGE/Pressy.app/Contents/MacOS/PressyBar"
cp Support/PressyBar-Info.plist "$STAGE/Pressy.app/Contents/Info.plist"
cp scripts/install.sh scripts/uninstall.sh "$STAGE/scripts/"
cp config.example.yaml README.md LICENSE "$STAGE/"
codesign --force --sign "$SIGN_IDENTITY" --identifier li.sudo.pressy "$STAGE/bin/pressy"
codesign --force --sign "$SIGN_IDENTITY" "$STAGE/Pressy.app"
codesign --verify --strict "$STAGE/bin/pressy" "$STAGE/Pressy.app"

ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "built $ZIP"
cat "$ZIP.sha256"
