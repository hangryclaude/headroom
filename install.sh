#!/bin/bash
# Install Headroom.app into /Applications and start it.
#
#   ./install.sh
#
# Two traps this avoids, both learned from an earlier tool:
#
# 1. `cp -r Headroom.app /Applications/` NESTS the bundle inside itself when the
#    destination already exists, leaving the old Contents/ running and reporting
#    no error at all. rsync with a trailing slash and --delete replaces contents
#    in place instead.
# 2. A running copy holds the old binary, so it is killed first by its bundle
#    path -- not by name, which would also match a debug build in .build/.

set -euo pipefail

cd "$(dirname "$0")"

APP=".build/Headroom.app"
DEST="/Applications/Headroom.app"

./build.sh release

pkill -f "Headroom.app/Contents/MacOS/Headroom" 2>/dev/null || true
sleep 0.5

mkdir -p "$DEST"
rsync -a --delete "$APP/" "$DEST/"

echo "installed  $DEST"
open "$DEST"

# SMAppService silently no-ops from a build directory, so launch-at-login is
# only meaningful once the app lives here. macOS may still park the request in
# "requires approval" — System Settings > General > Login Items.
echo "look for the percentage in your menu bar"
