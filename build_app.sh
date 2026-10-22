#!/bin/bash
# Usage:   bash build_app.sh                  ->  build/DropWheel.app   (ad-hoc signed, runs on this Mac)
#          SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash build_app.sh
# Env:     VERSION (default 0.3)   BUNDLE_ID (default com.dropwheel.app)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.3}"
BUNDLE_ID="${BUNDLE_ID:-com.dropwheel.app}"
SIGN="${SIGN_ID:--}"
APP="build/DropWheel.app"

echo "▸ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/DropWheel"
[ -x "$BIN" ] || { echo "✗ Build produced no binary at $BIN"; exit 1; }

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DropWheel"

ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DropWheel</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>DropWheel</string>
<key>CFBundleDisplayName</key><string>DropWheel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
${ICON_KEY}
<key>NSDesktopFolderUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
<key>NSDocumentsFolderUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
<key>NSDownloadsFolderUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
<key>NSRemovableVolumesUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
</dict></plist>
PLIST

echo "▸ Signing ($([ "$SIGN" = "-" ] && echo "ad-hoc" || echo "$SIGN"))"
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp --options runtime --sign "$SIGN" "$APP"
fi

echo "✓ Built $APP"
echo "  Run it:        open $APP"
echo "  Headless test: $APP/Contents/MacOS/DropWheel --engines"
