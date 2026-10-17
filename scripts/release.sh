#!/usr/bin/env bash
# Builds a release: dist/pressy-<version>-macos-arm64.zip and dist/pressy-<version>.pkg (installer),
# each with a .sha256; the programs inside are signed with the local
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
PKG="dist/$NAME.pkg"
rm -rf "$STAGE" "$ZIP" "$ZIP.sha256" "$PKG" "$PKG.sha256" dist/pkg

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

# Installer package: the release goes to /Library/Application Support/pressy/release, the postinstall
# script runs its install.sh as the logged-in user. Not signed (no Developer ID).
install -d "dist/pkg/root/Library/Application Support/pressy" dist/pkg/resources
ditto --norsrc --noextattr "$STAGE" "dist/pkg/root/Library/Application Support/pressy/release"
pkgbuild --root dist/pkg/root --scripts packaging/pkg/scripts --identifier li.sudo.pressy --version "$VERSION" \
  --install-location / dist/pkg/pressy-component.pkg >/dev/null
cp packaging/pkg/resources/*.html dist/pkg/resources/
cp LICENSE dist/pkg/resources/LICENSE
sed "s/@VERSION@/$VERSION/g" packaging/pkg/distribution.xml.in > dist/pkg/distribution.xml
productbuild --distribution dist/pkg/distribution.xml --resources dist/pkg/resources --package-path dist/pkg "$PKG" >/dev/null
rm -rf dist/pkg

(cd dist && for f in "$(basename "$ZIP")" "$(basename "$PKG")"; do shasum -a 256 "$f" > "$f.sha256"; done)
echo "built $ZIP and $PKG"
cat "$ZIP.sha256" "$PKG.sha256"
