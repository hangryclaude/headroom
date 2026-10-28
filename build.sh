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

# A stable designated requirement, so the bundle keeps one identity across
# rebuilds rather than a fresh code hash each time.
#
# Explicitly NOT load-bearing for Keychain access any more. It used to be the
# plan: sign stably, get on the credential item's ACL, stop the password
# prompts. That never worked for the CLI, which SwiftPM ad-hoc signs, so the two
# binaries held different identities and each swap locked the other out.
# Keychain.swift now puts nobody but /usr/bin/security on the ACL and reads
# through it, which is why none of this matters to it -- do not re-couple them.
#
# Falls back to ad-hoc rather than failing the build: an unsigned-but-working
# app beats no app on a machine without the certificate. Diagnostics are kept
# rather than sent to /dev/null, because "silently produced something different
# from what you asked for" is how the last several hours got spent.
SIGNING_IDENTITY="Headroom Local Code Signing"
if ! codesign --force --sign "$SIGNING_IDENTITY" "$APP"; then
    echo "warn   '$SIGNING_IDENTITY' unavailable — falling back to ad-hoc signing"
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" || {
    echo "error  the signature did not verify"
    exit 1
}

echo "built  $APP  ($CONFIG)"

if [[ "${2:-}" == "run" ]]; then
    pkill -x Headroom 2>/dev/null || true
    open "$APP"
fi
