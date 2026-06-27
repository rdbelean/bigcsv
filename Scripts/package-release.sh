#!/usr/bin/env bash
# Build, sign, notarize, and package the FREE direct/Homebrew build of BigCSV
# into a distributable .dmg, then print the values needed to update the cask.
#
# This builds the DIRECT_BUILD flavor: every Pro feature unlocked, no StoreKit.
# (The paid App Store build is produced separately via Xcode → Archive.)
#
# Usage:
#   Scripts/package-release.sh <version>            # real, signed + notarized
#   ALLOW_DEVELOPMENT_SIGNING=1 Scripts/package-release.sh <version>   # local test only
#
# Requirements for a real release:
#   1. A "Developer ID Application" certificate in your login keychain.
#        Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. A notarytool credential profile named "bigcsv-notary":
#        xcrun notarytool store-credentials bigcsv-notary \
#          --apple-id "you@example.com" --team-id ML728UQT9W \
#          --password "<app-specific-password from appleid.apple.com>"
#
# Output: dist/BigCSV-<version>.dmg  (+ the SHA256 and cask snippet to commit).
set -euo pipefail

VERSION="${1:?usage: package-release.sh <version>   e.g. 1.0}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
BUILD="$ROOT/.release-build"
APP_NAME="BigCSV"
NOTARY_PROFILE="bigcsv-notary"
DEV_ID_IDENTITY="Developer ID Application"

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

# ── Preflight ────────────────────────────────────────────────────────────────
SIGN_IDENTITY="$DEV_ID_IDENTITY"
if ! security find-identity -v -p codesigning | grep -q "$DEV_ID_IDENTITY"; then
  if [[ "${ALLOW_DEVELOPMENT_SIGNING:-0}" == "1" ]]; then
    echo "⚠️  No 'Developer ID Application' cert — falling back to Apple Development."
    echo "    The .dmg will run on YOUR Mac but NOT on other users' Macs (no notarization)."
    SIGN_IDENTITY="Apple Development"
  else
    echo "❌ No 'Developer ID Application' certificate found."
    echo "   Create one: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
    echo "   (or re-run with ALLOW_DEVELOPMENT_SIGNING=1 for a local-only test build)."
    exit 1
  fi
fi
echo "▶ Signing identity: $SIGN_IDENTITY"

# ── 1. Build the DIRECT_BUILD (free) flavor, Release, universal ──────────────
echo "▶ Building $APP_NAME $VERSION (direct/free flavor, universal)…"
xcodebuild -project bigcsv.xcodeproj -scheme bigcsv -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD/dd" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="DIRECT_BUILD" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  clean build | tail -3

APP="$BUILD/dd/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || APP="$BUILD/dd/Build/Products/Release/bigcsv.app"
[[ -d "$APP" ]] || { echo "❌ Build product not found under $BUILD/dd/Build/Products/Release"; exit 1; }
echo "▶ Built: $APP"
lipo -info "$APP/Contents/MacOS/"* 2>/dev/null || true

# ── 2. Sign (hardened runtime, required for notarization) ────────────────────
echo "▶ Signing with hardened runtime…"
codesign --force --deep --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ── 3. Package into a .dmg ───────────────────────────────────────────────────
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
echo "▶ Building $DMG…"
STAGING="$BUILD/dmg"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG" >/dev/null

# ── 4. Notarize + staple (skipped for development-signed test builds) ────────
if [[ "$SIGN_IDENTITY" == "$DEV_ID_IDENTITY" ]]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "▶ Submitting to Apple notary service (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "▶ Stapling ticket…"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  else
    echo "⚠️  Notary profile '$NOTARY_PROFILE' not found — DMG is signed but NOT notarized."
    echo "    Set it up: xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "                 --apple-id <you@example.com> --team-id ML728UQT9W --password <app-specific-pw>"
  fi
else
  echo "⚠️  Development-signed test build — skipping notarization."
fi

# ── 5. Report: SHA + cask snippet ────────────────────────────────────────────
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo ""
echo "✅ Done: $DMG"
echo "   SHA256: $SHA"
echo ""
echo "Update Casks/bigcsv.rb with:"
echo "   version \"$VERSION\""
echo "   sha256 \"$SHA\""

# Auto-patch the cask if present (version + sha256 lines).
CASK="$ROOT/Casks/bigcsv.rb"
if [[ -f "$CASK" ]]; then
  /usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
  /usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  echo "▶ Patched $CASK (commit it, then upload $DMG to the GitHub release)."
fi
