#!/bin/bash
# Assemble Headroom.app around the SwiftPM executable.
#
# This machine has Command Line Tools but not full Xcode, so `xcodebuild` is
# unavailable and SwiftPM cannot emit a bundle on its own. Everything a menu bar
# app needs from a bundle -- LSUIElement, a bundle identifier for notification
# and login-item registration -- is assembled here by hand.
#
#   ./build.sh              debug build into .build/Headroom.app
#   ./build.sh release      optimised
#   ./build.sh release run  build, then launch it

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP=".build/Headroom.app"
VERSION="0.1.0"

swift build -c "$CONFIG"
BIN=".build/$CONFIG/Headroom"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Headroom"

# The icon is generated from the same design tokens as the UI, so it cannot
# drift from the product. iconutil ships with the Command Line Tools.
"$BIN" --icon .build >/dev/null
iconutil -c icns .build/Headroom.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Headroom</string>
    <key>CFBundleDisplayName</key>       <string>Headroom</string>
    <key>CFBundleIdentifier</key>        <string>com.angus.headroom</string>
    <key>CFBundleExecutable</key>        <string>Headroom</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Angus</string>
</dict>
</plist>
PLIST

# Ad-hoc, because `security find-identity -p codesigning` reports no identities
# on this machine. Worth knowing what that costs: an ad-hoc signature is bound to
# the code hash, which changes on every rebuild, so the Keychain "Always Allow"
# grant for reading Claude Code's credential item does not survive a rebuild --
# macOS will prompt again each time. Creating a stable self-signed certificate
# and signing with that fixes it; see README.
codesign --force --sign - "$APP" 2>/dev/null

echo "built  $APP  ($CONFIG)"

if [[ "${2:-}" == "run" ]]; then
    pkill -x Headroom 2>/dev/null || true
    open "$APP"
fi
