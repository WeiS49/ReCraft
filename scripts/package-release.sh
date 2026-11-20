#!/usr/bin/env bash
# Build the Release app with ad-hoc signing and package it for a GitHub release.
#
#   scripts/package-release.sh v0.3.0
#
# Refuses when the tag does not match the app's version. Writes
# .build/release/ReCraft-<version>.zip and its .sha256 next to it, and prints
# the zip path on the last line. Needs no certificate, network or API key.
set -euo pipefail

TAG="${1:?usage: scripts/package-release.sh v<version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/check-derived"
OUT="$ROOT/.build/release"
LOG="$ROOT/.build/check-logs/package.log"
mkdir -p "$OUT" "$(dirname "$LOG")"

if ! xcodebuild build \
       -project "$ROOT/ReCraft.xcodeproj" -scheme ReCraft -configuration Release \
       -destination 'platform=macOS,arch=arm64' \
       -derivedDataPath "$DERIVED" \
       CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
       CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO > "$LOG" 2>&1; then
  grep -E "error:|: error " "$LOG" | sort -u | tail -40 >&2 || true
  echo "package: Release build failed. Full log in .build/check-logs/package.log" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Release/ReCraft.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$TAG" != "v$VERSION" ]; then
  echo "package: tag $TAG does not match the app version $VERSION." >&2
  echo "Set MARKETING_VERSION in project.yml and the Xcode project, or tag v$VERSION." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP"
signature="$(codesign -dv "$APP" 2>&1)"
if ! grep -q '^Signature=adhoc$' <<<"$signature"; then
  echo "package: the release app must be ad-hoc signed; found another signature." >&2
  exit 1
fi

ZIP="$OUT/ReCraft-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "$ZIP"
