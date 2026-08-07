#!/bin/bash
# Package Headroom.app into a drag-to-Applications disk image.
#
#   ./dmg.sh        dist/Headroom-<version>.dmg
#
# Only hdiutil is used. `create-dmg` would be one brew install away but this
# project takes no dependencies it does not ship, and hdiutil has been in the
# base system since the disk image format existed.
#
# The result cannot be signed or notarized: `security find-identity -p
# codesigning` reports no identities on this machine, so build.sh signs ad-hoc.
# That is not a packaging bug to work around, it is a fact a downloader will
# meet at first launch -- see the Gatekeeper notes printed at the end.

set -euo pipefail

cd "$(dirname "$0")"

APP=".build/Headroom.app"
VOLNAME="Headroom"

# Single source of truth: build.sh stamps the Info.plist, so read the version
# back out of it rather than keeping a second copy here that can drift.
VERSION="$(grep -m1 '^VERSION=' build.sh | cut -d'"' -f2)"
if [[ -z "$VERSION" ]]; then
    echo "dmg.sh: could not read VERSION from build.sh" >&2
    exit 1
fi

DMG="dist/Headroom-$VERSION.dmg"

STAGE=""
DEV=""

# A leaked mount is worse than a failed build: it survives the shell, holds the
# temp file open, and the user has to hunt for it in Finder. Unmount on every
# exit path, force if the first attempt finds it busy.
cleanup() {
    if [[ -n "$DEV" ]]; then
        hdiutil detach "$DEV" -quiet 2>/dev/null \
            || hdiutil detach "$DEV" -force -quiet 2>/dev/null \
            || true
        DEV=""
    fi
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

./build.sh release

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/headroom-dmg.XXXXXX")"

# The intermediate image and the scratch script live beside the payload, never
# inside it: hdiutil copies the srcfolder wholesale, so a file written there
# while it reads is either shipped in the DMG or fails the create outright.
PAYLOAD="$STAGE/payload"
mkdir -p "$PAYLOAD"
cp -R "$APP" "$PAYLOAD/Headroom.app"
ln -s /Applications "$PAYLOAD/Applications"

mkdir -p dist
rm -f "$DMG"

# HFS+ rather than APFS: the layout pass below depends on Finder writing a
# .DS_Store into the image, and HFS+ is the format every DMG tool has exercised
# for that. Read-write first, because a compressed image cannot be arranged.
# Not -quiet -- a silent hdiutil failure here is indistinguishable from a bug
# in this script, and the progress noise is a cheap price for a real error.
RW="$STAGE/rw.dmg"
hdiutil create -srcfolder "$PAYLOAD" -volname "$VOLNAME" \
    -fs HFS+ -format UDRW -ov "$RW"

# Another volume of the same name may already be mounted, in which case macOS
# appends a suffix -- so take the mount point hdiutil actually reports.
ATTACH="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen)"
DEV="$(printf '%s\n' "$ATTACH" | awk -F'\t' '/^\/dev\// && $NF ~ /^\/Volumes\// { gsub(/[ \t]+$/, "", $1); print $1; exit }')"
MOUNT="$(printf '%s\n' "$ATTACH" | awk -F'\t' '/^\/dev\// && $NF ~ /^\/Volumes\// { print $NF; exit }')"

if [[ -z "$DEV" || -z "$MOUNT" ]]; then
    echo "dmg.sh: hdiutil attach produced no mount point" >&2
    exit 1
fi

# Icon layout: AppleScript driving Finder, not a hand-written .DS_Store.
#
# Writing the .DS_Store directly is the only way to get a layout without
# Finder in the loop, but the format is undocumented and there is no encoder in
# the base system -- it would mean either a committed binary blob nobody can
# review or a third-party library, and this project takes neither. AppleScript
# is the standard approach and the only one available here.
#
# Its real failure mode is hanging, not erroring: Finder can block indefinitely
# on a modal sheet or a stalled volume, and an unattended build that never
# returns is worse than one with icons in the default grid. So it runs detached
# under a hard timeout, and a failure here costs cosmetics only.
LAYOUT="applied"
OSA="$STAGE/layout.applescript"
cat > "$OSA" <<APPLESCRIPT
tell application "Finder"
    tell disk "$(basename "$MOUNT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 160, 840, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        set position of item "Headroom.app" of container window to {150, 180}
        set position of item "Applications" of container window to {450, 180}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

osascript "$OSA" >/dev/null 2>&1 &
OSA_PID=$!
WAITED=0
while kill -0 "$OSA_PID" 2>/dev/null && [[ $WAITED -lt 30 ]]; do
    sleep 1
    WAITED=$((WAITED + 1))
done
if kill -0 "$OSA_PID" 2>/dev/null; then
    kill -9 "$OSA_PID" 2>/dev/null || true
    LAYOUT="degraded: Finder did not respond within 30s"
elif ! wait "$OSA_PID"; then
    LAYOUT="degraded: Finder rejected the layout script"
fi
wait "$OSA_PID" 2>/dev/null || true

# Give Finder's .DS_Store write a chance to reach the image before unmounting.
sync
chmod -Rf go-w "$MOUNT" 2>/dev/null || true

hdiutil detach "$DEV" -quiet 2>/dev/null || hdiutil detach "$DEV" -force -quiet
DEV=""

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
echo "built  $DMG  ($SIZE)"
echo "layout $LAYOUT"
echo
echo "Gatekeeper: this image is neither signed nor notarized, because no"
echo "codesigning identity exists on the build machine. Anyone who DOWNLOADS it"
echo "gets a quarantine flag, and the first launch of Headroom.app is blocked"
echo "outright -- macOS 15 and later no longer accept right-click > Open as a"
echo "bypass for a quarantined unsigned app, so telling them to do that wastes"
echo "their time."
echo
echo "What actually works, once they have dragged the app to Applications:"
echo "  1. Open Headroom from Applications. The launch is refused."
echo "  2. Go to System Settings > Privacy & Security and scroll to the"
echo "     security section near the bottom. A line about Headroom being"
echo "     blocked appears there with an Open Anyway button next to it."
echo "     (Exact label wording shifts between macOS releases -- look for the"
echo "     Headroom entry and the button beside it rather than a literal"
echo "     string. It only appears AFTER a blocked launch attempt.)"
echo "  3. Authenticate, then confirm Open Anyway. This is once per install."
echo
echo "\`xattr -cr /Applications/Headroom.app\` strips the quarantine flag and"
echo "skips all of the above, but it also skips the check, so it belongs in a"
echo "footnote for people who know what they are giving up -- not in the"
echo "install instructions. Copying the app off this machine directly, rather"
echo "than downloading it, sets no quarantine flag and needs none of this."
