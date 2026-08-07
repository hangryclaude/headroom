#!/bin/bash
# Regenerate every image in the README.
#
#   ./docs/shoot.sh
#
# Two stages. `Headroom --render` photographs the real SwiftUI views with a real
# Store behind them, pointed by HEADROOM_HOME at a throwaway tree from
# docs/fixture.py -- so the numbers in the shots are invented and the author's
# account addresses stay off the internet. Then ImageMagick frames each surface
# the way it actually appears on screen: rounded corners, a soft shadow, and a
# transparent canvas, because a baked-in background can only match one of
# GitHub's two themes.
#
# Needs: a Swift 6 toolchain, python3, ImageMagick 7.

set -euo pipefail
cd "$(dirname "$0")/.."

DOCS=docs
WORK="${TMPDIR:-/tmp}/headroom-shoot.$$"
RAW="$WORK/raw"
FIXTURE="$WORK/home"
mkdir -p "$RAW" "$FIXTURE"
trap 'rm -rf "$WORK"' EXIT

for tool in python3 magick; do
    command -v "$tool" >/dev/null || { echo "need $tool"; exit 1; }
done

# The surface colour behind each appearance's content. Sampled rather than
# guessed: the render leaves a few fully transparent rows where negative padding
# pushes a divider outside the background, and flattening onto the wrong colour
# would draw a seam along the top edge.
LIGHT_BG="#ffffff"
DARK_BG="#171717"

# A hairline along each card's own edge.
#
# Not decoration. GitHub serves the README on #ffffff or #0d1117 depending on the
# reader's theme, and a #171717 card on #0d1117 has a 1.1:1 boundary -- the
# screenshot dissolves into the page and the shadow alone does not save it. The
# rim gives every card an edge in both themes without touching the UI's colours.
LIGHT_RIM="rgba(0,0,0,0.14)"
DARK_RIM="rgba(255,255,255,0.11)"

# macOS draws an NSPopover at a 10pt corner radius, and these are 2x renders.
RADIUS=20

# ---------------------------------------------------------------------------

say() { printf '  %s\n' "$*"; }

# frame <in> <out> <surface-colour> <rim-colour> [radius] [padding]
#
# The +compose reset is load-bearing: -layers merge honours whatever compose
# method is still set, so leaving CopyOpacity in place from the corner mask
# silently merges the artwork into the shadow's alpha and writes a black box.
frame() {
    local in=$1 out=$2 bg=$3 rim=$4 r=${5:-$RADIUS} pad=${6:-28} w h
    w=$(magick "$in" -format "%w" info:)
    h=$(magick "$in" -format "%h" info:)

    magick "$in" -background "$bg" -alpha remove -alpha off \
        -fill none -stroke "$rim" -strokewidth 2 \
        -draw "roundrectangle 1,1 $((w - 2)),$((h - 2)) $((r - 1)),$((r - 1))" \
        \( -size "${w}x${h}" xc:black -fill white \
           -draw "roundrectangle 0,0 $((w - 1)),$((h - 1)) $r,$r" -alpha off \) \
        -compose CopyOpacity -composite \
        +compose -colorspace sRGB \
        \( +clone -background black -shadow 42x16+0+10 \) +swap \
        -background none -compose Over -layers merge +repage \
        -bordercolor none -border "$pad" \
        -define png:color-type=6 \
        -strip "$out"
}

# ---------------------------------------------------------------------------

echo "==> fixture"
python3 "$DOCS/fixture.py" "$FIXTURE" >/dev/null
say "$FIXTURE"

echo "==> build"
swift build -c release >/dev/null
BIN=.build/release/Headroom

echo "==> render"
HEADROOM_HOME="$FIXTURE" "$BIN" --render "$RAW" >/dev/null
say "$(ls "$RAW" | tr '\n' ' ')"

# The icon comes out of the same binary as the UI, so regenerate it here too --
# otherwise the README and the social card can go on showing a mark the app no
# longer draws.
"$BIN" --icon "$WORK" >/dev/null
cp "$WORK/Headroom.iconset/icon_512x512.png" "$DOCS/icon.png"

echo "==> frame"
for mode in light dark; do
    bg=$LIGHT_BG rim=$LIGHT_RIM
    [[ $mode == dark ]] && { bg=$DARK_BG; rim=$DARK_RIM; }

    # The dropdown, whole. Served through <picture> in the README so a reader on
    # GitHub's dark theme gets the dark one and nobody is shown the appearance
    # they do not use.
    frame "$RAW/popover-$mode.png" "$DOCS/popover-$mode.png" "$bg" "$rim"

    # Just the instrument: three windows, three gauges, the pace read. Cropped
    # tight because the section it illustrates is an argument about those rows
    # and nothing below them.
    magick "$RAW/popover-$mode.png" -crop "840x232+0+0" +repage -strip "$WORK/instrument-$mode.png"
    frame "$WORK/instrument-$mode.png" "$DOCS/instrument-$mode.png" "$bg" "$rim" "$RADIUS" 24

    # The detail panel is ~1900px tall, which in a README is a column nobody
    # reads. Split it at the cost section and set the halves side by side.
    #
    # The upper half is shorter, so its canvas is extended to the lower half's
    # height before framing. Two panes of equal size read as one surface split in
    # two; a short card beside a tall one reads as a mistake.
    #
    # These offsets are measured off the render, so a layout change moves them.
    # The banner below prints every output's dimensions for exactly that reason.
    magick "$RAW/panel-$mode.png" -crop "920x878+0+0" +repage \
        -background "$bg" -gravity north -extent 920x1034 \
        -strip "$WORK/panel-top-$mode.png"
    magick "$RAW/panel-$mode.png" -crop "920x1034+0+878" +repage \
        -strip "$WORK/panel-bottom-$mode.png"
    frame "$WORK/panel-top-$mode.png" "$WORK/f-panel-top-$mode.png" "$bg" "$rim" "$RADIUS" 24
    frame "$WORK/panel-bottom-$mode.png" "$WORK/f-panel-bottom-$mode.png" "$bg" "$rim" "$RADIUS" 24
    magick "$WORK/f-panel-top-$mode.png" "$WORK/f-panel-bottom-$mode.png" \
        -background none -gravity north +append +repage \
        -define png:color-type=6 -strip "$DOCS/panel-$mode.png"

    frame "$RAW/onboarding-$mode.png" "$DOCS/onboarding-$mode.png" "$bg" "$rim"
done

# The Open Graph card, at the one size GitHub does not crop.
#
# Worth its own step because GitHub never uses a README image for this: without
# it, every link shared to X, Slack, Discord or Hacker News renders as a grey
# fallback slab with an avatar on it. Built from the same assets as the README so
# it cannot drift from what the app looks like.
echo "==> social card"
SF=/System/Library/Fonts/SFNS.ttf
if [[ -f $SF ]]; then
    # Sized so the card clears both tagline lines and the repo URL. Widen it and
    # it starts eating the copy from the right.
    magick "$WORK/instrument-dark.png" -resize 680x "$WORK/social-card.png"
    frame "$WORK/social-card.png" "$WORK/social-inset.png" "$DARK_BG" "$DARK_RIM" 18 20

    magick -size 1280x640 gradient:"#231F1B"-"#0D0C0B" -colorspace sRGB \
        \( "$DOCS/icon.png" -resize 112x112 \) -geometry +76+80 -compose Over -composite \
        -font "$SF" -fill "#F7F6F4" -pointsize 78 -annotate +74+300 "Headroom" \
        -font "$SF" -fill "#A19C95" -pointsize 29 \
            -annotate +76+352 "Claude Code quota in your macOS menu bar." \
        -font "$SF" -fill "#A19C95" -pointsize 29 \
            -annotate +76+394 "One click swaps between your Claude accounts." \
        -font "$SF" -fill "#615C57" -pointsize 24 \
            -annotate +76+566 "github.com/hangryclaude/headroom" \
        \( "$WORK/social-inset.png" \) -gravity southeast -geometry +-26+-24 \
            -compose Over -composite \
        -define png:color-type=6 -strip "$DOCS/social-preview.png"
else
    say "skipped: $SF not found"
fi

echo "==> written"
for f in "$DOCS"/*.png; do
    printf '  %-26s %sx%s  %s\n' "$(basename "$f")" \
        "$(magick "$f" -format "%w" info:)" \
        "$(magick "$f" -format "%h" info:)" \
        "$(du -h "$f" | cut -f1 | tr -d ' ')"
done
