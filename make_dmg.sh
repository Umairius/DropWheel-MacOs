#!/bin/bash
# Builds build/DropWheel.dmg (+ build/DropWheel.zip for the curl-installer / GitHub Releases).
#
#   bash make_dmg.sh                         small DMG; ffmpeg + pandoc download on first launch (the setup window)
#   BUNDLE_TOOLS=1 bash make_dmg.sh          bundle ffmpeg + pandoc inside the app: ~300 MB, nothing to download
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash make_dmg.sh
#   SIGN_ID="..." NOTARY_PROFILE=dropwheel bash make_dmg.sh     sign + notarize + staple (removes the Gatekeeper wall)
#
# One-time notary setup:  xcrun notarytool store-credentials dropwheel --apple-id YOU --team-id TEAMID
#
# Tools match the architecture of the binary being packaged. LibreOffice is never bundled (huge).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.3}"
SIGN="${SIGN_ID:--}"
APP="build/DropWheel.app"
DMG="build/DropWheel.dmg"
ZIP="build/DropWheel.zip"
FFMPEG_TAG="b6.0"          # eugeneware/ffmpeg-static
PANDOC_VERSION="3.12.1"    # jgm/pandoc   (same pins the in-app setup window uses)
CACHE=".cache/tools"

say()  { printf '▸ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

sign() {
  if [ "$SIGN" = "-" ]; then codesign --force --sign - "$@"
  else codesign --force --timestamp --options runtime --sign "$SIGN" "$@"; fi
}

# Download once, reuse next time. (No GitHub API: it rate-limits. Direct release URLs don't.)
fetch() {
  local url="$1" out="$2"
  if [ ! -s "$out" ]; then
    mkdir -p "$(dirname "$out")"
    curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url" || fail "Download failed: $url"
    mv "$out.part" "$out"
  fi
}

# 1. Build ----------------------------------------------------------------------------------
say "Building the app"
VERSION="$VERSION" SIGN_ID="${SIGN_ID:-}" bash build_app.sh >/dev/null
[ -d "$APP" ] || fail "build_app.sh did not produce $APP"

# 2. Optionally bundle helpers --------------------------------------------------------------
if [ "${BUNDLE_TOOLS:-0}" = "1" ]; then
  ARCH="$(lipo -archs "$APP/Contents/MacOS/DropWheel" 2>/dev/null | awk '{print $1}')"
  [ -n "$ARCH" ] || ARCH="$(uname -m)"
  case "$ARCH" in
    arm64)  FF_ARCH="arm64"; PD_ARCH="arm64"  ;;
    x86_64) FF_ARCH="x64";   PD_ARCH="x86_64" ;;
    *) fail "Unknown architecture: $ARCH" ;;
  esac

  say "Bundling ffmpeg + pandoc ($ARCH)"
  BIN_DIR="$APP/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"

  fetch "https://github.com/eugeneware/ffmpeg-static/releases/download/$FFMPEG_TAG/ffmpeg-darwin-$FF_ARCH" \
        "$CACHE/ffmpeg-$FFMPEG_TAG-$FF_ARCH"
  cp "$CACHE/ffmpeg-$FFMPEG_TAG-$FF_ARCH" "$BIN_DIR/ffmpeg"

  fetch "https://github.com/jgm/pandoc/releases/download/$PANDOC_VERSION/pandoc-$PANDOC_VERSION-$PD_ARCH-macOS.zip" \
        "$CACHE/pandoc-$PANDOC_VERSION-$PD_ARCH.zip"
  PD_TMP="$(mktemp -d)"
  ditto -x -k "$CACHE/pandoc-$PANDOC_VERSION-$PD_ARCH.zip" "$PD_TMP"
  PD_BIN="$(find "$PD_TMP" -path '*/bin/pandoc' -type f | head -1)"
  [ -n "$PD_BIN" ] || fail "pandoc binary not found inside the zip"
  cp "$PD_BIN" "$BIN_DIR/pandoc"
  rm -rf "$PD_TMP"

  chmod 755 "$BIN_DIR"/*
  xattr -cr "$BIN_DIR" 2>/dev/null || true

  say "Signing bundled tools, then the app (inside-out)"
  for f in "$BIN_DIR"/*; do sign "$f"; done
  sign "$APP"

  # If a bundled tool can't start, find out now, not on a customer's Mac.
  "$BIN_DIR/ffmpeg" -version | head -1
  "$BIN_DIR/pandoc" --version | head -1
else
  say "Not bundling tools: they download on first launch (BUNDLE_TOOLS=1 to bundle)"
fi

# 3. Verify the signature -------------------------------------------------------------------
say "Verifying signature"
codesign --verify --deep --strict "$APP" || fail "Signature check failed"

# 4. DMG + zip ------------------------------------------------------------------------------
say "Creating $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/DropWheel.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DropWheel" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 5. Sign + notarize the DMG ----------------------------------------------------------------
if [ "$SIGN" != "-" ]; then
  say "Signing the DMG"
  codesign --force --timestamp --sign "$SIGN" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "$SIGN" != "-" ] || fail "Notarizing needs SIGN_ID (a Developer ID Application certificate)."
  say "Notarizing (a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "✓ $DMG  ($SIZE)"
echo "✓ $ZIP"
if [ "$SIGN" = "-" ]; then
  echo
  echo "Heads up: ad-hoc signed. Other Macs will show the 'unidentified developer' warning:"
  echo "System Settings → Privacy & Security → Open Anyway. A Developer ID + notarization removes that."
fi
